# The C MEX gateway: one file of generated C per library, holding the
# conversions between `mxArray` and the carriers, one handler per entry
# point, and the `mexFunction` that dispatches by name. The parts that do
# not vary live in `matlab_prologue.c.in` and `matlab_status.c.in`.

"""
    MATLAB_ERROR_IDENTIFIERS :: Dict{Int, String}

The MATLAB error identifier each `JLWStatus.code` becomes, so a caller gets
`ME.identifier` dispatch on the shared status codes. A code outside this
table falls back to `jlw:error`.
"""
const MATLAB_ERROR_IDENTIFIERS = Dict{Int, String}(
    1 => "jlw:error", 2 => "jlw:argument", 3 => "jlw:dimension",
    4 => "jlw:inexact", 5 => "jlw:bounds",
)

"""
    _matlab_c_template(name; substitutions...) -> String

A generated-C template from this package's `src`, with each `@NAME@` filled
in. The templates hold the parts of the gateway that are the same for every
library, so they can be read and edited as C. Throws when a placeholder is
left over, which means the template and this file disagree.
"""
function _matlab_c_template(name::AbstractString; substitutions...)
    text = read(joinpath(@__DIR__, name), String)
    for (key, value) in substitutions
        text = replace(text, "@" * uppercase(String(key)) * "@" => value)
    end
    left = match(r"@[A-Z_]+@", text)
    isnothing(left) ||
        error("$name: no substitution for $(left.match)")
    return text
end

"""
    _write_matlab_gateway_prologue(io, dest, header, message_bytes)

Write the gateway's includes, its library loader and its status check, from
`matlab_prologue.c.in` and `matlab_status.c.in`.

The library is opened here rather than linked, and never closed. Nothing
releases that reference, so `clear mex` unloading the MEX file leaves the
library mapped and the next load finds it rather than running `jl_init` a
second time; `RTLD_NODELETE` guards the same invariant against anything else
closing it. Opening it locally keeps its names out of the global namespace,
which is where a second wrapped library would otherwise meet them.
"""
function _write_matlab_gateway_prologue(
        io::IO, dest::MatlabTarget, header::AbstractString,
        message_bytes::Union{Int, Nothing}
    )
    # The MEX file lands in `+<package>/private`, so two levels up is the
    # directory `library_subdir` is relative to. This is what a package can
    # be moved or downloaded by: it holds however it was built.
    relative = "../../" * (
        isempty(dest.library_subdir) ? "" : join(splitpath(dest.library_subdir), "/") * "/"
    ) * dest.library_basename
    print(
        io, _matlab_c_template(
            "matlab_prologue.c.in";
            types_header = header,
            library_basename = dest.library_basename,
            library_relative = relative,
            library_env = uppercase(sanitize_for_c(dest.library_basename)) *
                "_MEX_LIBRARY",
        )
    )

    # The status check is emitted only when the library reports a status.
    isnothing(message_bytes) && return nothing
    cases = join(
        [
            "        case $code: identifier = \"$(MATLAB_ERROR_IDENTIFIERS[code])\"; break;"
                for code in sort(collect(keys(MATLAB_ERROR_IDENTIFIERS)))
        ], "\n"
    )
    print(
        io, _matlab_c_template(
            "matlab_status.c.in";
            message_bytes = string(message_bytes), status_cases = cases,
        )
    )
    return nothing
end

"""
    _matlab_status_message_bytes(typeinfo) -> Union{Int, Nothing}

The size of `JLWStatus.message`, read from the ABI rather than assumed, or
`nothing` when the library declares no `JLWStatus`. A library of
hand-written entry points may skip the status channel; then the gateway has
no errors to translate.
"""
function _matlab_status_message_bytes(typeinfo::OrderedDict{Int, TypeDesc})
    for desc in values(typeinfo)
        desc isa StructDesc || continue
        is_jlwstatus_struct(desc, typeinfo) || continue
        field = only(f for f in desc.fields if f.name == "message")
        return (typeinfo[field.type]::ArrayDesc).count
    end
    return nothing
end

"""
    _matlab_raise_if(condition, id, message) -> String

One guard in a handler: raise `message` under `id` when `condition` holds.
"""
function _matlab_raise_if(
        condition::AbstractString, id::AbstractString, message::AbstractString
    )
    return """
        if ($condition) {
            mexErrMsgIdAndTxt("$id", "$message");
        }
    """
end

"""
    _matlab_check(plan, symbol) -> String

The validation phase of one handler: everything that can raise, before
anything is acquired. `mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no
cleanup, so a check that raises while a carrier is live would leak it. Class,
shape, and sparsity checks hold no carrier, so they all run first. `nlhs` is
known before the call, so the output count is checked here too.
"""
function _matlab_check(plan, symbol::AbstractString)
    parts = String[]
    total = length(plan.mutates) + length(_matlab_result_outputs(plan.ret))
    if total > 1
        push!(
            parts, """
                int wanted = nlhs < 1 ? 1 : nlhs;
            """
        )
        push!(parts, _matlab_raise_if("wanted > $total", "jlw:argument", "at most $total outputs"))
    end
    push!(
        parts, _matlab_raise_if(
            "nrhs != $(length(plan.args) + 1)", "jlw:argument",
            "$symbol takes $(length(plan.args)) arguments"
        )
    )
    for (i, kind) in pairs(plan.args)
        argument = "prhs[$i]"
        name = i <= length(plan.positional) ? plan.positional[i] :
            plan.keywords[i - length(plan.positional)]
        class = uppercasefirst(get(kind, :class, ""))
        if kind.kind in (:array, :scalar, :opt, :dict)
            # A sparse mxArray passes a class check but stores (i, j, v)
            # triples, so borrowing it as a dense buffer would read the wrong
            # memory.
            push!(
                parts, _matlab_raise_if(
                    "mxIsSparse($argument)", "jlw:argument", "$name must not be sparse"
                )
            )
        end
        if kind.kind === :scalar
            push!(
                parts, _matlab_raise_if(
                    "!mxIs$class($argument) || mxGetNumberOfElements($argument) != 1",
                    "jlw:argument", "$name must be a $(kind.class) scalar"
                )
            )
        elseif kind.kind === :array
            push!(
                parts, _matlab_raise_if(
                    "!mxIs$class($argument)", "jlw:argument", "$name must be $(kind.class)"
                )
            )
            push!(
                parts, _matlab_raise_if(
                    "mxGetNumberOfDimensions($argument) > $(max(kind.ndim, 2))",
                    "jlw:dimension", "$name has too many dimensions"
                )
            )
        elseif kind.kind === :string
            push!(
                parts, _matlab_raise_if(
                    "!mxIsChar($argument)", "jlw:argument", "$name must be char"
                )
            )
        elseif kind.kind === :strarray
            push!(
                parts, _matlab_raise_if(
                    "!mxIsCell($argument)", "jlw:argument",
                    "$name must be a cell array of char"
                )
            )
        elseif kind.kind === :dict
            push!(
                parts, _matlab_raise_if(
                    "!mxIsStruct($argument)", "jlw:argument", "$name must be a struct"
                )
            )
        elseif kind.kind === :opt
            # The class is checked as it is for a scalar: the value is read
            # through the accessor for it, which needs the class to match.
            push!(
                parts, _matlab_raise_if(
                    "!mxIsEmpty($argument) && (!mxIs$class($argument) || " *
                        "mxGetNumberOfElements($argument) != 1)",
                    "jlw:argument", "$name must be a $(kind.class) scalar or []"
                )
            )
        end
    end
    return join(parts)
end

"""
    _matlab_accessor(class) -> String

The `-R2018a` typed data accessor for a MATLAB class. These return a pointer to
the mxArray's own buffer, which is what lets an array argument be borrowed
rather than copied.
"""
_matlab_accessor(class::AbstractString) = "mxGet" *
    (class == "logical" ? "Logicals" : uppercasefirst(class) * "s")

"""
    _matlab_class_id(class) -> String

The `mxClassID` naming a MATLAB class, for `mxCreateNumericArray`.
"""
_matlab_class_id(class::AbstractString) = "mx" * uppercase(class) * "_CLASS"

"""
    _matlab_create_array(class, rank, shape) -> String
    _matlab_create_scalar(class, rows, cols) -> String

The `mxCreate…` call for a class. `logical` has its own creators:
`mxCreateNumericArray` takes a numeric `mxClassID`, and `mxLOGICAL_CLASS` is
not one of them.
"""
_matlab_create_array(class::AbstractString, rank, shape::AbstractString) =
    class == "logical" ? "mxCreateLogicalArray(" * string(rank) * ", " * shape * ")" :
    "mxCreateNumericArray(" * string(rank) * ", " * shape * ", " *
    _matlab_class_id(class) * ", mxREAL)"

_matlab_create_scalar(class::AbstractString, rows, cols) =
    class == "logical" ?
    "mxCreateLogicalMatrix(" * string(rows) * ", " * string(cols) * ")" :
    "mxCreateNumericMatrix(" * string(rows) * ", " * string(cols) * ", " *
    _matlab_class_id(class) * ", mxREAL)"

"""
    _matlab_ctype(class) -> String

The C type behind a MATLAB class, as the generated header spells it.
"""
function _matlab_ctype(class::AbstractString)
    class == "double" && return "double"
    class == "single" && return "float"
    # The header spells `Bool` as C's `bool`.
    class == "logical" && return "bool"
    return class * "_t"
end

"""
    _matlab_length_type(bits) -> String

The C type of a carrier's length or dimension field. The real carriers are
64-bit but some hand-written fixtures are 32-bit, so the width comes from
the recognizers, not an assumption.
"""
_matlab_length_type(bits::Integer) = "int" * string(bits) * "_t"

"""
    _matlab_length_guard(indent, expression, bits, what) -> String

Guard a count that has to fit a 32-bit field: `mwSize` is unsigned and
64-bit, so a larger value would truncate to a negative number in Julia.
Nothing is held at these sites, so raising is safe. A 64-bit field needs no
guard, and the fragment is then empty.
"""
function _matlab_length_guard(
        indent::AbstractString, expression::AbstractString,
        bits::Integer, what::AbstractString
    )
    bits >= 64 && return ""
    return """
    $(indent)if ($expression > INT32_MAX) {
    $(indent)    mexErrMsgIdAndTxt("jlw:dimension", "$what exceeds this library's 32-bit length field");
    $(indent)}
    """
end

"""
    _matlab_in_body(name, kind) -> String

The body of the helper that converts an `mxArray` into carrier `name`, or
`nothing` for a kind that has no conversion.
"""
function _matlab_in_body(name::AbstractString, kind)
    if kind.kind === :array
        length_type = _matlab_length_type(kind.dims_bits)
        if kind.ndim == 1
            dims = _matlab_length_guard(
                "    ", "mxGetNumberOfElements(value)", kind.dims_bits,
                "the vector's length"
            )
            dims *= """
                carrier.dims[0] = ($length_type)mxGetNumberOfElements(value);
            """
        else
            dims = """
                const mwSize *shape = mxGetDimensions(value);
                mwSize rank = mxGetNumberOfDimensions(value);
                for (int i = 0; i < $(kind.ndim); i++) {
                    /* MATLAB drops trailing singletons, so a missing
                       dimension is 1 rather than an error. */
            """
            dims *= _matlab_length_guard(
                "        ", "(i < (int)rank ? shape[i] : 1)", kind.dims_bits, "a dimension"
            )
            dims *= """
                    carrier.dims[i] = ($length_type)(i < (int)rank ? shape[i] : 1);
                }
            """
        end
        tail = """
            carrier.data = ($(_matlab_ctype(kind.class)) *)$(_matlab_accessor(kind.class))(value);
            return carrier;
        """
        return "    $name carrier;\n" * dims * tail
    elseif kind.kind === :string
        head = """
            /* From `mxMalloc`, so it is reclaimed even if an error unwinds past here. */
            char *text = mxArrayToUTF8String(value);
            if (text == NULL) {
                mexErrMsgIdAndTxt("jlw:argument", "could not read char data");
            }
            size_t size = strlen(text);
        """
        guard = _matlab_length_guard("    ", "size", kind.length_bits, "the string")
        tail = """
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))size;
            carrier.data = (uint8_t *)text;
            return carrier;
        """
        return head * guard * tail
    elseif kind.kind === :strarray
        head = """
            mwSize count = mxGetNumberOfElements(value);
            CString_borrowed *items =
                (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
            for (mwSize i = 0; i < count; i++) {
                const mxArray *cell = mxGetCell(value, i);
                if (cell == NULL || !mxIsChar(cell)) {
                    mexErrMsgIdAndTxt("jlw:argument", "every cell must be char");
                }
                char *text = mxArrayToUTF8String(cell);
                if (text == NULL) {
                    mexErrMsgIdAndTxt("jlw:argument", "could not read char data");
                }
                size_t size = strlen(text);
        """
        element_guard = _matlab_length_guard(
            "        ", "size", kind.element_bits, "a string"
        )
        middle = """
                items[i].length = ($(_matlab_length_type(kind.element_bits)))size;
                items[i].data = (uint8_t *)text;
            }
        """
        count_guard = _matlab_length_guard(
            "    ", "count", kind.length_bits, "the cell array"
        )
        tail = """
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))count;
            carrier.data = items;
            return carrier;
        """
        return head * element_guard * middle * count_guard * tail
    elseif kind.kind === :dict
        ctype = _matlab_ctype(kind.class)
        return """
            int count = mxGetNumberOfFields(value);
            CString_borrowed *keys =
                (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
            $ctype *values =
                ($ctype *)mxMalloc((count ? count : 1) * sizeof($ctype));
            for (int i = 0; i < count; i++) {
                const char *key = mxGetFieldNameByNumber(value, i);
                /* A MATLAB field name is at most `mxMAXNAM` bytes, so the
                   length needs no width guard and fits the narrowest field
                   a `CString` can carry. */
                keys[i].length = (int32_t)strlen(key);
                keys[i].data = (uint8_t *)key;
                const mxArray *field = mxGetFieldByNumber(value, 0, i);
                /* A sparse field passes a class check and has no
                   dense buffer to read. */
                if (field == NULL || mxIsSparse(field) ||
                    !mxIs$(uppercasefirst(kind.class))(field) ||
                    mxGetNumberOfElements(field) != 1) {
                    mexErrMsgIdAndTxt("jlw:argument",
                        "field %s must be a $(kind.class) scalar", key);
                }
                values[i] = *$(_matlab_accessor(kind.class))(field);
            }
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))count;
            carrier.keys = keys;
            carrier.values = values;
            return carrier;
        """
    elseif kind.kind === :opt
        ctype = _matlab_ctype(kind.class)
        return """
            $name carrier;
            if (mxIsEmpty(value)) {
                carrier.has_value = 0;
                carrier.value = ($ctype)0;
            } else {
                carrier.has_value = 1;
                carrier.value = *$(_matlab_accessor(kind.class))(value);
            }
            return carrier;
        """
    end
    return nothing
end

"""
    _write_matlab_in_helpers(io, carriers)

Write one conversion helper per borrowed carrier an argument uses.

Each takes an already-validated `mxArray` and returns a carrier over MATLAB's
storage. What they allocate comes from `mxMalloc`, which MATLAB reclaims when
`mexFunction` exits, so an unwind past them is safe.
"""
function _write_matlab_in_helpers(io::IO, carriers)
    for (name, kind) in carriers
        body = _matlab_in_body(name, kind)
        isnothing(body) && continue
        print(
            io, """

            static $name jlw_in_$name(const mxArray *value)
            {
            $(body)}
            """
        )
    end
    return nothing
end

"""
    _write_matlab_field_name_check(io)

Write the predicate for a legal MATLAB field name. A dictionary return checks
its keys, and so does a tuple holding one, so it is emitted once and called
from both.
"""
function _write_matlab_field_name_check(io::IO)
    print(
        io, """

        static int jlw_valid_field_name(const uint8_t *data, int32_t n)
        {
            if (n <= 0 || n >= mxMAXNAM) {
                return 0;
            }
            for (int32_t j = 0; j < n; j++) {
                uint8_t c = data[j];
                int alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
                int rest = (c >= '0' && c <= '9') || c == '_';
                /* A field name starts with a letter. */
                if (!(j == 0 ? alpha : (alpha || rest))) {
                    return 0;
                }
            }
            return 1;
        }
        """
    )
    return nothing
end

"""
    _write_matlab_release(io)

Write cached wrappers for the library's deallocation entry points. They are
resolved once: a `dlsym` per release would cost a lookup on every returned
value.
"""
function _write_matlab_release(io::IO)
    # `void *`: the header declares the carrier typedef only when an entry
    # point uses it, so a carrier-free library still compiles.
    print(
        io, """

        static void jlw_release(void *pointer)
        {
            static void (*entry)(void *) = NULL;
            if (entry == NULL) {
                entry = (void (*)(void *))jlw_symbol("jlw_free");
            }
            entry(pointer);
        }

        static void jlw_release_strings(void *items, int64_t count)
        {
            static void (*entry)(void *, int64_t) = NULL;
            if (entry == NULL) {
                entry = (void (*)(void *, int64_t))jlw_symbol("jlw_free_strings");
            }
            entry(items, count);
        }
        """
    )
    return nothing
end

"""
    _matlab_out_body(kind) -> String

The body of the helper that turns carrier `kind` into an `mxArray`. It also
releases what Julia allocated, which is why every element of a tuple return is
converted even when the caller wants fewer outputs.
"""
function _matlab_out_body(kind)
    # One spelling of the release, from the same place the tuple unwind uses.
    release = join(
        "    $statement\n" for statement in _matlab_release_expression(kind, "carrier")
    )
    if kind.kind === :array
        rank = max(kind.ndim, 2)
        shape = """
            mwSize shape[$rank] = {$(join(fill("1", rank), ", "))};
        """
        shape *= join(
            "    shape[$(d - 1)] = (mwSize)carrier.dims[$(d - 1)];\n" for d in 1:kind.ndim
        )
        body = """
            mxArray *out = $(_matlab_create_array(kind.class, rank, "shape"));
            memcpy($(_matlab_accessor(kind.class))(out), carrier.data,
                   mxGetNumberOfElements(out) * sizeof($(_matlab_ctype(kind.class))));
        """
        return shape * body * release
    elseif kind.kind === :string
        head = """
            /* `mxCreateString` takes a C string, so an embedded NUL
               truncates; Julia permits them. */
            char *text = (char *)mxMalloc((size_t)carrier.length + 1);
            memcpy(text, carrier.data, (size_t)carrier.length);
            text[carrier.length] = '\\0';
        """
        tail = """
            mxArray *out = mxCreateString(text);
            mxFree(text);
        """
        return head * release * tail
    elseif kind.kind === :strarray
        body = """
            mxArray *out = mxCreateCellMatrix((mwSize)carrier.length, 1);
            for (int64_t i = 0; i < carrier.length; i++) {
                char *text = (char *)mxMalloc((size_t)carrier.data[i].length + 1);
                memcpy(text, carrier.data[i].data, (size_t)carrier.data[i].length);
                text[carrier.data[i].length] = '\\0';
                mxSetCell(out, (mwSize)i, mxCreateString(text));
                mxFree(text);
            }
        """
        return body * release
    elseif kind.kind === :dict
        head = """
            /* Keys are checked before anything is created, so a bad
               one is reported while nothing is held. */
            for (int64_t i = 0; i < carrier.length; i++) {
                if (!jlw_valid_field_name(carrier.keys[i].data, carrier.keys[i].length)) {
        """
        # Two levels deeper than the tail release: inside the loop and the `if`.
        head *= join(
            "            $statement\n"
                for statement in _matlab_release_expression(kind, "carrier")
        )
        body = """
                    mexErrMsgIdAndTxt("jlw:argument",
                        "a dictionary key is not a legal MATLAB field name");
                }
            }
            const char **names =
                (const char **)mxMalloc((size_t)(carrier.length ? carrier.length : 1) * sizeof(char *));
            for (int64_t i = 0; i < carrier.length; i++) {
                char *key = (char *)mxMalloc((size_t)carrier.keys[i].length + 1);
                memcpy(key, carrier.keys[i].data, (size_t)carrier.keys[i].length);
                key[carrier.keys[i].length] = '\\0';
                names[i] = key;
            }
            mxArray *out = mxCreateStructMatrix(1, 1, (int)carrier.length, names);
            for (int64_t i = 0; i < carrier.length; i++) {
                mxArray *field = $(_matlab_create_scalar(kind.class, 1, 1));
                *$(_matlab_accessor(kind.class))(field) = ($(_matlab_ctype(kind.class)))carrier.values[i];
                mxSetFieldByNumber(out, 0, (int)i, field);
            }
        """
        return head * body * release
    elseif kind.kind === :opt
        return """
            if (carrier.has_value == 0) {
                return $(_matlab_create_scalar(kind.class, 0, 0));
            }
            mxArray *out = $(_matlab_create_scalar(kind.class, 1, 1));
            *$(_matlab_accessor(kind.class))(out) = carrier.value;
        """
    elseif kind.kind === :scalar
        return """
            mxArray *out = $(_matlab_create_scalar(kind.class, 1, 1));
            *$(_matlab_accessor(kind.class))(out) = carrier;
        """
    end
    return ""
end

"""
    _write_matlab_out_helpers(io, carriers)

Write one conversion helper per distinct return carrier, each copying Julia's
storage into a fresh `mxArray` and releasing the original.

A helper that can raise between acquiring and releasing frees first:
`mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no cleanup, so every exit
path releases explicitly.
"""
function _write_matlab_out_helpers(io::IO, carriers)
    for (name, kind) in carriers
        print(
            io, """

            static mxArray *jlw_out_$name($name carrier)
            {
            $(_matlab_out_body(kind))    return out;
            }
            """
        )
    end
    return nothing
end

"""
    _matlab_element_access(fields, i) -> String

How the gateway reaches element `i` of a `CNTuple`'s inner tuple. juliac emits
that tuple as a struct whose fields are the positions when the element types
differ, and as an inline array when they are all one type.
"""
_matlab_element_access(fields, i::Int) =
    isnothing(fields) ? "[" * string(i - 1) * "]" : "." * sanitize_for_c(fields[i])

"""
    _write_matlab_handler(io, plan, symbol, names)

Write one entry point's handler: validate, borrow the arguments, call, check
the status, then convert and assign the results.
"""
function _write_matlab_handler(io::IO, plan, symbol::AbstractString, names)
    # Handlers share one signature, so a void or single-output one leaves
    # parameters unused; a MEX build with warnings on would say so.
    copies = String["copy$i" for i in plan.mutates]
    total = length(copies) + length(_matlab_result_outputs(plan.ret))
    unused = String[]
    total > 1 || push!(unused, "    (void)nlhs;\n")
    total == 0 && push!(unused, "    (void)plhs;\n")
    isempty(plan.args) && push!(unused, "    (void)prhs;\n")

    conversions = map(eachindex(plan.args)) do i
        kind = plan.args[i]
        source = "prhs[$i]"
        if i in plan.mutates
            # The wrapped function writes here, and MATLAB's own buffer may
            # be shared with variables the caller never passed. The copy is
            # what comes back.
            source = "copy$i"
            text = "    mxArray *copy$i = mxDuplicateArray(prhs[$i]);\n"
            return text * "    $(names.args[i]) arg$i = jlw_in_$(names.args[i])($source);\n"
        end
        kind.kind === :scalar || return "    $(names.args[i]) arg$i = jlw_in_$(names.args[i])($source);\n"
        ctype = _matlab_ctype(kind.class)
        return "    $ctype arg$i = *$(_matlab_accessor(kind.class))($source);\n"
    end

    signature = isempty(plan.args) ? "void" :
        join(
            [
                plan.args[i].kind === :scalar ? _matlab_ctype(plan.args[i].class) : names.args[i]
                for i in eachindex(plan.args)
            ], ", "
        )
    arguments = join(["arg" * string(i) for i in eachindex(plan.args)], ", ")
    call = "((" * names.result * " (*)(" * signature * "))jlw_symbol(\"" *
        symbol * "\"))(" * arguments * ");"

    ret = plan.ret
    if ret.kind === :none
        # Nothing is returned, so there is nothing to name or check.
        tail = "    $call\n" * _matlab_assign("", copies)
    else
        # On a failure the value is zero-filled, so the check raises while
        # holding nothing; that is what lets it run before any conversion.
        results = if ret.kind === :result
            "    jlw_check(result.status);\n" *
                _matlab_results(ret.inner, "result.value", names, copies)
        elseif ret.kind === :void
            "    jlw_check(result);\n" * _matlab_assign("", copies)
        else
            _matlab_results(ret, "result", names, copies)
        end
        tail = """
                $(names.result) result =
                    $call
            """ * results
    end

    print(
        io, """

        static void jlw_call_$symbol
            (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
        {
        $(join(unused))$(_matlab_check(plan, symbol))$(join(conversions))$(tail)}
        """
    )
    return nothing
end
"""
    _matlab_results(ret, expression, names) -> String

Assign an entry point's results into `plhs`.

A caller may request fewer outputs than a declaration produces; every element
is converted regardless, because conversion is what releases Julia's storage
for it. An unrequested element's `mxArray` is destroyed instead of assigned.
"""
function _matlab_results(ret, expression::AbstractString, names, copies::Vector{String})
    values = copy(copies)
    ret.kind in (:void, :none) && return _matlab_assign("", values)
    if ret.kind !== :tuple
        # One output and nothing else to place: assign it where it is made.
        isempty(values) &&
            return "    plhs[0] = jlw_out_$(names.value)($expression);\n"
        push!(values, "out1")
        return _matlab_assign(
            "    mxArray *out1 = jlw_out_$(names.value)($expression);\n", values
        )
    end
    accesses = [
        expression * ".values" * _matlab_element_access(ret.fields, i)
            for i in eachindex(ret.elements)
    ]
    text = _matlab_tuple_precheck(ret, accesses)
    text *= join(
        "    mxArray *out$i = jlw_out_$(names.elements[i])($(accesses[i]));\n"
            for i in eachindex(ret.elements)
    )
    append!(values, "out$i" for i in eachindex(ret.elements))
    return _matlab_assign(text, values)
end

"""
    _matlab_assign(text, values) -> String

Put each output in `plhs`, after `text` has made it. One output goes straight
there. Two or more are placed only as far as the caller asked, and the rest
destroyed, since an `mxArray` nobody takes is the gateway's to release.
"""
function _matlab_assign(text::AbstractString, values::Vector{String})
    isempty(values) && return String(text)
    length(values) == 1 && return text * "    plhs[0] = $(only(values));\n"
    for (k, value) in pairs(values)
        text *= """
            if (wanted >= $k) {
                plhs[$(k - 1)] = $value;
            } else {
                mxDestroyArray($value);
            }
        """
    end
    return String(text)
end

"""
    _matlab_carrier_names(method, typedict, typeinfo) -> NamedTuple

The C type names the gateway needs for one entry point: the argument carriers,
the entry point's own return type, the payload under a `JLWResult`, and a
tuple payload's elements. They come from [`mangle_c!`](@ref), so they are the
same spellings the emitted header declares.
"""
function _matlab_carrier_names(
        method::MethodDesc, typedict::Dict{Int, String},
        typeinfo::OrderedDict{Int, TypeDesc}
    )
    args = String[mangle_c!(typedict, a.type, typeinfo) for a in method.args]
    result = mangle_c!(typedict, method.return_type, typeinfo)

    value_id = method.return_type
    if !isnothing(value_id)
        desc = typeinfo[value_id]
        if desc isa StructDesc
            wrapper = jlwresult_struct_info(desc, typeinfo)
            isnothing(wrapper) || (value_id = wrapper.value_type_id)
        end
    end
    value = isnothing(value_id) ? "void" : mangle_c!(typedict, value_id, typeinfo)

    elements = String[]
    if !isnothing(value_id)
        desc = typeinfo[value_id]
        if desc isa StructDesc
            info = ctuple_struct_info(desc, typeinfo)
            isnothing(info) ||
                (elements = String[mangle_c!(typedict, id, typeinfo) for id in info.element_type_ids])
        end
    end
    return (; args, result, value, elements)
end

"""
    _write_matlab_gateway(io, dest, abi_info, plans, header)

Write the whole gateway: prologue, the conversion helpers each carrier needs,
one handler per entry point, and the `mexFunction` that dispatches by name.
"""
function _write_matlab_gateway(io::IO, dest::MatlabTarget, abi_info::ABIInfo, plans, header)
    (; typeinfo) = abi_info
    typedict = Dict{Int, String}()
    named = [(method, plan, _matlab_carrier_names(method, typedict, typeinfo)) for (method, plan) in plans]

    _write_matlab_gateway_prologue(io, dest, header, _matlab_status_message_bytes(typeinfo))
    _write_matlab_field_name_check(io)
    _write_matlab_release(io)

    # One helper per distinct carrier: its memory discipline lives in a single
    # place.
    incoming = OrderedDict{String, Any}()
    outgoing = OrderedDict{String, Any}()
    for (_, plan, names) in named
        for (i, kind) in pairs(plan.args)
            kind.kind === :scalar || (incoming[names.args[i]] = kind)
        end
        ret = plan.ret.kind === :result ? plan.ret.inner : plan.ret
        if ret.kind === :tuple
            for (i, element) in pairs(ret.elements)
                outgoing[names.elements[i]] = element
            end
        elseif ret.kind ∉ (:void, :none)
            outgoing[names.value] = ret
        end
    end
    _write_matlab_in_helpers(io, incoming)
    _write_matlab_out_helpers(io, outgoing)

    for (method, plan, names) in named
        _write_matlab_handler(io, plan, method.symbol, names)
    end

    dispatch = ""
    if isempty(named)
        dispatch = """
            (void)nlhs;
            (void)plhs;
            mexErrMsgIdAndTxt("jlw:argument", "no wrapped functions");
        """
    else
        # Read the dispatch name only when a function is wrapped; an empty
        # gateway would carry an unused variable.
        dispatch = "    char *name = mxArrayToUTF8String(prhs[0]);\n"
        for (i, (method, _, _)) in pairs(named)
            keyword = i == 1 ? "    if" : "    } else if"
            dispatch *= "$keyword (strcmp(name, \"$(method.symbol)\") == 0) {\n"
            dispatch *= "        jlw_call_$(method.symbol)(nlhs, plhs, nrhs, prhs);\n"
        end
        dispatch *= """
            } else {
                mexErrMsgIdAndTxt("jlw:argument", "unknown function %s", name);
            }
        """
    end
    print(
        io, """

        void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
        {
            if (nrhs < 1 || !mxIsChar(prhs[0])) {
                mexErrMsgIdAndTxt("jlw:argument", "the first argument names the function");
            }
        $(dispatch)}
        """
    )
    return nothing
end

"""
    _matlab_release_expression(kind, access) -> Vector{String}

The statements that release a carrier's storage without converting it. The out
helpers release this way once they have copied, and a tuple whose elements are
produced but not yet converted unwinds this way.
"""
function _matlab_release_expression(kind, access::AbstractString)
    kind.owns || return String[]
    kind.kind === :strarray &&
        return ["jlw_release_strings(" * access * ".data, " * access * ".length);"]
    kind.kind === :dict && return [
        "jlw_release_strings(" * access * ".keys, " * access * ".length);",
        "jlw_release(" * access * ".values);",
    ]
    return ["jlw_release(" * access * ".data);"]
end

"""
    _matlab_tuple_precheck(ret, accesses) -> String

Validate every dictionary element's field names before any element of a tuple
is converted.

Conversion is also what releases an element, so a raise part-way would strand
the unconverted ones. Dictionary keys are runtime data from Julia, so this is
an ordinary path, not an edge case. Checking first means a raise happens
while the whole tuple is still intact and can be released.
"""
function _matlab_tuple_precheck(ret, accesses)
    # Releasing every element, including the one being checked, since none has
    # been converted yet.
    unwind = join(
        "            $statement\n"
            for (element, access) in zip(ret.elements, accesses)
            for statement in _matlab_release_expression(element, access)
    )
    text = ""
    for (element, access) in zip(ret.elements, accesses)
        element.kind === :dict || continue
        text *= """
            for (int64_t k = 0; k < $access.length; k++) {
                if (!jlw_valid_field_name($access.keys[k].data, $access.keys[k].length)) {
        """
        text *= unwind
        text *= """
                    mexErrMsgIdAndTxt("jlw:argument",
                        "a dictionary key is not a legal MATLAB field name");
                }
            }
        """
    end
    return text
end
