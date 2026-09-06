static void jlw_call_EnumFixture_pick
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "EnumFixture_pick takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "x must not be sparse");
    }
    if (!mxIsDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "x must be a double scalar");
    }
    double arg1 = (double)mxGetScalar(prhs[1]);
    JLWResult_Int32 result =
        ((JLWResult_Int32 (*)(double))jlw_symbol("EnumFixture_pick"))(arg1);
    jlw_check(result.status);
    plhs[0] = jlw_out_int32_t(result.value);
}

static void jlw_call_EnumFixture_scale_by
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 3) {
        mexErrMsgIdAndTxt("jlw:argument", "EnumFixture_scale_by takes 2 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "x must not be sparse");
    }
    if (!mxIsDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "x must be a double scalar");
    }
    if (mxIsSparse(prhs[2])) {
        mexErrMsgIdAndTxt("jlw:argument", "penalty must not be sparse");
    }
    if (!mxIsInt32(prhs[2]) || mxGetNumberOfElements(prhs[2]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "penalty must be a int32 scalar");
    }
    double arg1 = (double)mxGetScalar(prhs[1]);
    int32_t arg2 = (int32_t)mxGetScalar(prhs[2]);
    JLWResult_Float64 result =
        ((JLWResult_Float64 (*)(double, int32_t))jlw_symbol("EnumFixture_scale_by"))(arg1, arg2);
    jlw_check(result.status);
    plhs[0] = jlw_out_double(result.value);
}

static void jlw_call_bundle
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)prhs;
    int wanted = nlhs < 1 ? 1 : nlhs;
    if (wanted > 4) {
        mexErrMsgIdAndTxt("jlw:argument", "at most 4 outputs");
    }
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "bundle takes 0 arguments");
    }
    JLWResult_CNTuple_4_Tuple_CString_owned_CStrArray_owned_CDict_owned_Float64_COpt_Float64 result =
        ((JLWResult_CNTuple_4_Tuple_CString_owned_CStrArray_owned_CDict_owned_Float64_COpt_Float64 (*)(void))jlw_symbol("bundle"))();
    jlw_check(result.status);
    for (int64_t k = 0; k < result.value.values._3.length; k++) {
        if (!jlw_valid_field_name(result.value.values._3.keys[k].data, result.value.values._3.keys[k].length)) {
            jlw_release(result.value.values._1.data);
            jlw_release_strings(result.value.values._2.data, result.value.values._2.length);
            jlw_release_strings(result.value.values._3.keys, result.value.values._3.length);
            jlw_release(result.value.values._3.values);
            mexErrMsgIdAndTxt("jlw:argument",
                "a dictionary key is not a legal MATLAB field name");
        }
    }
    mxArray *out1 = jlw_out_CString_owned(result.value.values._1);
    mxArray *out2 = jlw_out_CStrArray_owned(result.value.values._2);
    mxArray *out3 = jlw_out_CDict_owned_Float64(result.value.values._3);
    mxArray *out4 = jlw_out_COpt_Float64(result.value.values._4);
    if (wanted >= 1) {
        plhs[0] = out1;
    } else {
        mxDestroyArray(out1);
    }
    if (wanted >= 2) {
        plhs[1] = out2;
    } else {
        mxDestroyArray(out2);
    }
    if (wanted >= 3) {
        plhs[2] = out3;
    } else {
        mxDestroyArray(out3);
    }
    if (wanted >= 4) {
        plhs[3] = out4;
    } else {
        mxDestroyArray(out4);
    }
}

static void jlw_call_do_thing
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)plhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "do_thing takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "x must not be sparse");
    }
    if (!mxIsInt32(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "x must be a int32 scalar");
    }
    int32_t arg1 = (int32_t)mxGetScalar(prhs[1]);
    JLWStatus result =
        ((JLWStatus (*)(int32_t))jlw_symbol("do_thing"))(arg1);
    jlw_check(result);
}

static void jlw_call_give_dict
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_dict takes 0 arguments");
    }
    CDict_owned_Float64 result =
        ((CDict_owned_Float64 (*)(void))jlw_symbol("give_dict"))();
    plhs[0] = jlw_out_CDict_owned_Float64(result);
}

static void jlw_call_give_dict_i32
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_dict_i32 takes 0 arguments");
    }
    CDict_owned_Int32 result =
        ((CDict_owned_Int32 (*)(void))jlw_symbol("give_dict_i32"))();
    plhs[0] = jlw_out_CDict_owned_Int32(result);
}

static void jlw_call_give_greeting
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_greeting takes 0 arguments");
    }
    CString_owned result =
        ((CString_owned (*)(void))jlw_symbol("give_greeting"))();
    plhs[0] = jlw_out_CString_owned(result);
}

static void jlw_call_give_opt
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_opt takes 0 arguments");
    }
    COpt_Float64 result =
        ((COpt_Float64 (*)(void))jlw_symbol("give_opt"))();
    plhs[0] = jlw_out_COpt_Float64(result);
}

static void jlw_call_give_strs
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_strs takes 0 arguments");
    }
    CStrArray_owned result =
        ((CStrArray_owned (*)(void))jlw_symbol("give_strs"))();
    plhs[0] = jlw_out_CStrArray_owned(result);
}

static void jlw_call_give_vec
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "give_vec takes 0 arguments");
    }
    CVector_owned_Float64 result =
        ((CVector_owned_Float64 (*)(void))jlw_symbol("give_vec"))();
    plhs[0] = jlw_out_CVector_owned_Float64(result);
}

static void jlw_call_greet
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "greet takes 0 arguments");
    }
    JLWResult_CString_owned result =
        ((JLWResult_CString_owned (*)(void))jlw_symbol("greet"))();
    jlw_check(result.status);
    plhs[0] = jlw_out_CString_owned(result.value);
}

static void jlw_call_greeting
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "greeting takes 0 arguments");
    }
    CString_borrowed result =
        ((CString_borrowed (*)(void))jlw_symbol("greeting"))();
    plhs[0] = jlw_out_CString_borrowed(result);
}

static void jlw_call_greeting_length
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "greeting_length takes 1 arguments");
    }
    if (!mxIsChar(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "s must be char");
    }
    CString_borrowed arg1 = jlw_in_CString_borrowed(prhs[1]);
    int32_t result =
        ((int32_t (*)(CString_borrowed))jlw_symbol("greeting_length"))(arg1);
    plhs[0] = jlw_out_int32_t(result);
}

static void jlw_call_mylib_count_true
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "mylib_count_true takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "v must not be sparse");
    }
    if (!mxIsLogical(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "v must be logical");
    }
    if (mxGetNumberOfDimensions(prhs[1]) > 2) {
        mexErrMsgIdAndTxt("jlw:dimension", "v has too many dimensions");
    }
    CVector_borrowed_Bool arg1 = jlw_in_CVector_borrowed_Bool(prhs[1]);
    int64_t result =
        ((int64_t (*)(CVector_borrowed_Bool))jlw_symbol("mylib_count_true"))(arg1);
    plhs[0] = jlw_out_int64_t(result);
}

static void jlw_call_mylib_mask
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "mylib_mask takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "n must not be sparse");
    }
    if (!mxIsInt64(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "n must be a int64 scalar");
    }
    int64_t arg1 = (int64_t)mxGetScalar(prhs[1]);
    CVector_owned_Bool result =
        ((CVector_owned_Bool (*)(int64_t))jlw_symbol("mylib_mask"))(arg1);
    plhs[0] = jlw_out_CVector_owned_Bool(result);
}

static void jlw_call_mylib_scale
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "mylib_scale takes 0 arguments");
    }
    JLWResult_Float64 result =
        ((JLWResult_Float64 (*)(void))jlw_symbol("mylib_scale"))();
    jlw_check(result.status);
    plhs[0] = jlw_out_double(result.value);
}

static void jlw_call_mylib_scale
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 4) {
        mexErrMsgIdAndTxt("jlw:argument", "mylib_scale takes 3 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "x must not be sparse");
    }
    if (!mxIsDouble(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "x must be double");
    }
    if (mxGetNumberOfDimensions(prhs[1]) > 2) {
        mexErrMsgIdAndTxt("jlw:dimension", "x has too many dimensions");
    }
    if (mxIsSparse(prhs[2])) {
        mexErrMsgIdAndTxt("jlw:argument", "factor must not be sparse");
    }
    if (!mxIsDouble(prhs[2]) || mxGetNumberOfElements(prhs[2]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "factor must be a double scalar");
    }
    if (!mxIsChar(prhs[3])) {
        mexErrMsgIdAndTxt("jlw:argument", "label must be char");
    }
    CVector_borrowed_Float64 arg1 = jlw_in_CVector_borrowed_Float64(prhs[1]);
    double arg2 = (double)mxGetScalar(prhs[2]);
    CString_borrowed arg3 = jlw_in_CString_borrowed(prhs[3]);
    JLWResult_CVector_owned_Float64 result =
        ((JLWResult_CVector_owned_Float64 (*)(CVector_borrowed_Float64, double, CString_borrowed))jlw_symbol("mylib_scale"))(arg1, arg2, arg3);
    jlw_check(result.status);
    plhs[0] = jlw_out_CVector_owned_Float64(result.value);
}

static void jlw_call_pair
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)prhs;
    int wanted = nlhs < 1 ? 1 : nlhs;
    if (wanted > 2) {
        mexErrMsgIdAndTxt("jlw:argument", "at most 2 outputs");
    }
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "pair takes 0 arguments");
    }
    JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64 result =
        ((JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64 (*)(void))jlw_symbol("pair"))();
    jlw_check(result.status);
    mxArray *out1 = jlw_out_CVector_owned_Float64(result.value.values[0]);
    mxArray *out2 = jlw_out_CVector_owned_Float64(result.value.values[1]);
    if (wanted >= 1) {
        plhs[0] = out1;
    } else {
        mxDestroyArray(out1);
    }
    if (wanted >= 2) {
        plhs[1] = out2;
    } else {
        mxDestroyArray(out2);
    }
}

static void jlw_call_plain_add
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 3) {
        mexErrMsgIdAndTxt("jlw:argument", "plain_add takes 2 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "a must not be sparse");
    }
    if (!mxIsInt32(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "a must be a int32 scalar");
    }
    if (mxIsSparse(prhs[2])) {
        mexErrMsgIdAndTxt("jlw:argument", "b must not be sparse");
    }
    if (!mxIsInt32(prhs[2]) || mxGetNumberOfElements(prhs[2]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "b must be a int32 scalar");
    }
    int32_t arg1 = (int32_t)mxGetScalar(prhs[1]);
    int32_t arg2 = (int32_t)mxGetScalar(prhs[2]);
    int32_t result =
        ((int32_t (*)(int32_t, int32_t))jlw_symbol("plain_add"))(arg1, arg2);
    plhs[0] = jlw_out_int32_t(result);
}

static void jlw_call_stats
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)prhs;
    int wanted = nlhs < 1 ? 1 : nlhs;
    if (wanted > 2) {
        mexErrMsgIdAndTxt("jlw:argument", "at most 2 outputs");
    }
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "stats takes 0 arguments");
    }
    JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_Int64 result =
        ((JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_Int64 (*)(void))jlw_symbol("stats"))();
    jlw_check(result.status);
    mxArray *out1 = jlw_out_CVector_owned_Float64(result.value.values._1);
    mxArray *out2 = jlw_out_int64_t(result.value.values._2);
    if (wanted >= 1) {
        plhs[0] = out1;
    } else {
        mxDestroyArray(out1);
    }
    if (wanted >= 2) {
        plhs[1] = out2;
    } else {
        mxDestroyArray(out2);
    }
}

static void jlw_call_sum3d
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "sum3d takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "a must not be sparse");
    }
    if (!mxIsDouble(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "a must be double");
    }
    if (mxGetNumberOfDimensions(prhs[1]) > 3) {
        mexErrMsgIdAndTxt("jlw:dimension", "a has too many dimensions");
    }
    CArray_borrowed_Float64_3 arg1 = jlw_in_CArray_borrowed_Float64_3(prhs[1]);
    double result =
        ((double (*)(CArray_borrowed_Float64_3))jlw_symbol("sum3d"))(arg1);
    plhs[0] = jlw_out_double(result);
}

static void jlw_call_take_dict
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "take_dict takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "d must not be sparse");
    }
    if (!mxIsStruct(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "d must be a struct");
    }
    CDict_borrowed_Float64 arg1 = jlw_in_CDict_borrowed_Float64(prhs[1]);
    int64_t result =
        ((int64_t (*)(CDict_borrowed_Float64))jlw_symbol("take_dict"))(arg1);
    plhs[0] = jlw_out_int64_t(result);
}

static void jlw_call_take_dict_i32
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "take_dict_i32 takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "d must not be sparse");
    }
    if (!mxIsStruct(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "d must be a struct");
    }
    CDict_borrowed_Int32 arg1 = jlw_in_CDict_borrowed_Int32(prhs[1]);
    int64_t result =
        ((int64_t (*)(CDict_borrowed_Int32))jlw_symbol("take_dict_i32"))(arg1);
    plhs[0] = jlw_out_int64_t(result);
}

static void jlw_call_take_opt
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "take_opt takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "o must not be sparse");
    }
    if (!mxIsEmpty(prhs[1]) && mxGetNumberOfElements(prhs[1]) != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "o must be a scalar or []");
    }
    COpt_Float64 arg1 = jlw_in_COpt_Float64(prhs[1]);
    double result =
        ((double (*)(COpt_Float64))jlw_symbol("take_opt"))(arg1);
    plhs[0] = jlw_out_double(result);
}

static void jlw_call_take_strs
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "take_strs takes 1 arguments");
    }
    if (!mxIsCell(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "a must be a cell array of char");
    }
    CStrArray_borrowed arg1 = jlw_in_CStrArray_borrowed(prhs[1]);
    int64_t result =
        ((int64_t (*)(CStrArray_borrowed))jlw_symbol("take_strs"))(arg1);
    plhs[0] = jlw_out_int64_t(result);
}

static void jlw_call_tally
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    (void)prhs;
    if (nrhs != 1) {
        mexErrMsgIdAndTxt("jlw:argument", "tally takes 0 arguments");
    }
    JLWResult_CDict_owned_Float64 result =
        ((JLWResult_CDict_owned_Float64 (*)(void))jlw_symbol("tally"))();
    jlw_check(result.status);
    plhs[0] = jlw_out_CDict_owned_Float64(result.value);
}

static void jlw_call_trace_cmatrix
    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("jlw:argument", "trace_cmatrix takes 1 arguments");
    }
    if (mxIsSparse(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "m must not be sparse");
    }
    if (!mxIsDouble(prhs[1])) {
        mexErrMsgIdAndTxt("jlw:argument", "m must be double");
    }
    if (mxGetNumberOfDimensions(prhs[1]) > 2) {
        mexErrMsgIdAndTxt("jlw:dimension", "m has too many dimensions");
    }
    CMatrix_borrowed_Float64 arg1 = jlw_in_CMatrix_borrowed_Float64(prhs[1]);
    double result =
        ((double (*)(CMatrix_borrowed_Float64))jlw_symbol("trace_cmatrix"))(arg1);
    plhs[0] = jlw_out_double(result);
}

static CArray_borrowed_Float64_3 jlw_in_CArray_borrowed_Float64_3(const mxArray *value)
{
    /* The caller asked for copies: a wrapped function that
       writes to its argument would otherwise corrupt every
       MATLAB variable sharing this buffer. The duplicate is
       reclaimed when `mexFunction` exits. */
    value = mxDuplicateArray(value);
    CArray_borrowed_Float64_3 carrier;
    const mwSize *shape = mxGetDimensions(value);
    mwSize rank = mxGetNumberOfDimensions(value);
    for (int i = 0; i < 3; i++) {
        /* MATLAB drops trailing singletons, so a missing
           dimension is 1 rather than an error. */
        carrier.dims[i] = (int64_t)(i < (int)rank ? shape[i] : 1);
    }
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static CArray_borrowed_Float64_3 jlw_in_CArray_borrowed_Float64_3(const mxArray *value)
{
    CArray_borrowed_Float64_3 carrier;
    const mwSize *shape = mxGetDimensions(value);
    mwSize rank = mxGetNumberOfDimensions(value);
    for (int i = 0; i < 3; i++) {
        /* MATLAB drops trailing singletons, so a missing
           dimension is 1 rather than an error. */
        carrier.dims[i] = (int64_t)(i < (int)rank ? shape[i] : 1);
    }
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static CDict_borrowed_Float64 jlw_in_CDict_borrowed_Float64(const mxArray *value)
{
    int count = mxGetNumberOfFields(value);
    CString_borrowed *keys =
        (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
    double *values =
        (double *)mxMalloc((count ? count : 1) * sizeof(double));
    for (int i = 0; i < count; i++) {
        const char *key = mxGetFieldNameByNumber(value, i);
        keys[i].length = (int32_t)strlen(key);
        /* A MATLAB field name is at most `mxMAXNAM`, so it fits. */
        keys[i].data = (uint8_t *)key;
        const mxArray *field = mxGetFieldByNumber(value, 0, i);
        /* A sparse field passes a class check and has no
           dense buffer to read. */
        if (field == NULL || mxIsSparse(field) ||
            !mxIsDouble(field) ||
            mxGetNumberOfElements(field) != 1) {
            mexErrMsgIdAndTxt("jlw:argument",
                "field %s must be a double scalar", key);
        }
        values[i] = *mxGetDoubles(field);
    }
    CDict_borrowed_Float64 carrier;
    carrier.length = (int64_t)count;
    carrier.keys = keys;
    carrier.values = values;
    return carrier;
}

static CDict_borrowed_Int32 jlw_in_CDict_borrowed_Int32(const mxArray *value)
{
    int count = mxGetNumberOfFields(value);
    CString_borrowed *keys =
        (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
    int32_t *values =
        (int32_t *)mxMalloc((count ? count : 1) * sizeof(int32_t));
    for (int i = 0; i < count; i++) {
        const char *key = mxGetFieldNameByNumber(value, i);
        keys[i].length = (int32_t)strlen(key);
        /* A MATLAB field name is at most `mxMAXNAM`, so it fits. */
        keys[i].data = (uint8_t *)key;
        const mxArray *field = mxGetFieldByNumber(value, 0, i);
        /* A sparse field passes a class check and has no
           dense buffer to read. */
        if (field == NULL || mxIsSparse(field) ||
            !mxIsInt32(field) ||
            mxGetNumberOfElements(field) != 1) {
            mexErrMsgIdAndTxt("jlw:argument",
                "field %s must be a int32 scalar", key);
        }
        values[i] = *mxGetInt32s(field);
    }
    CDict_borrowed_Int32 carrier;
    carrier.length = (int64_t)count;
    carrier.keys = keys;
    carrier.values = values;
    return carrier;
}

static CMatrix_borrowed_Float64 jlw_in_CMatrix_borrowed_Float64(const mxArray *value)
{
    /* The caller asked for copies: a wrapped function that
       writes to its argument would otherwise corrupt every
       MATLAB variable sharing this buffer. The duplicate is
       reclaimed when `mexFunction` exits. */
    value = mxDuplicateArray(value);
    CMatrix_borrowed_Float64 carrier;
    const mwSize *shape = mxGetDimensions(value);
    mwSize rank = mxGetNumberOfDimensions(value);
    for (int i = 0; i < 2; i++) {
        /* MATLAB drops trailing singletons, so a missing
           dimension is 1 rather than an error. */
        carrier.dims[i] = (int64_t)(i < (int)rank ? shape[i] : 1);
    }
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static CMatrix_borrowed_Float64 jlw_in_CMatrix_borrowed_Float64(const mxArray *value)
{
    CMatrix_borrowed_Float64 carrier;
    const mwSize *shape = mxGetDimensions(value);
    mwSize rank = mxGetNumberOfDimensions(value);
    for (int i = 0; i < 2; i++) {
        /* MATLAB drops trailing singletons, so a missing
           dimension is 1 rather than an error. */
        carrier.dims[i] = (int64_t)(i < (int)rank ? shape[i] : 1);
    }
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static COpt_Float64 jlw_in_COpt_Float64(const mxArray *value)
{
    COpt_Float64 carrier;
    if (mxIsEmpty(value)) {
        carrier.has_value = 0;
        carrier.value = (double)0;
    } else {
        carrier.has_value = 1;
        carrier.value = (double)mxGetScalar(value);
    }
    return carrier;
}

static CStrArray_borrowed jlw_in_CStrArray_borrowed(const mxArray *value)
{
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
        items[i].length = (int64_t)size;
        items[i].data = (uint8_t *)text;
    }
    CStrArray_borrowed carrier;
    carrier.length = (int64_t)count;
    carrier.data = items;
    return carrier;
}

static CString_borrowed jlw_in_CString_borrowed(const mxArray *value)
{
    /* From `mxMalloc`, so it is reclaimed even if an error unwinds past here. */
    char *text = mxArrayToUTF8String(value);
    if (text == NULL) {
        mexErrMsgIdAndTxt("jlw:argument", "could not read char data");
    }
    size_t size = strlen(text);
    CString_borrowed carrier;
    carrier.length = (int64_t)size;
    carrier.data = (uint8_t *)text;
    return carrier;
}

static CVector_borrowed_Bool jlw_in_CVector_borrowed_Bool(const mxArray *value)
{
    /* The caller asked for copies: a wrapped function that
       writes to its argument would otherwise corrupt every
       MATLAB variable sharing this buffer. The duplicate is
       reclaimed when `mexFunction` exits. */
    value = mxDuplicateArray(value);
    CVector_borrowed_Bool carrier;
    if (mxGetNumberOfElements(value) > INT32_MAX) {
        mexErrMsgIdAndTxt("jlw:dimension", "the vector's length exceeds this library's 32-bit length field");
    }
    carrier.dims[0] = (int32_t)mxGetNumberOfElements(value);
    carrier.data = (bool *)mxGetLogicals(value);
    return carrier;
}

static CVector_borrowed_Bool jlw_in_CVector_borrowed_Bool(const mxArray *value)
{
    CVector_borrowed_Bool carrier;
    if (mxGetNumberOfElements(value) > INT32_MAX) {
        mexErrMsgIdAndTxt("jlw:dimension", "the vector's length exceeds this library's 32-bit length field");
    }
    carrier.dims[0] = (int32_t)mxGetNumberOfElements(value);
    carrier.data = (bool *)mxGetLogicals(value);
    return carrier;
}

static CVector_borrowed_Float64 jlw_in_CVector_borrowed_Float64(const mxArray *value)
{
    /* The caller asked for copies: a wrapped function that
       writes to its argument would otherwise corrupt every
       MATLAB variable sharing this buffer. The duplicate is
       reclaimed when `mexFunction` exits. */
    value = mxDuplicateArray(value);
    CVector_borrowed_Float64 carrier;
    carrier.dims[0] = (int64_t)mxGetNumberOfElements(value);
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static CVector_borrowed_Float64 jlw_in_CVector_borrowed_Float64(const mxArray *value)
{
    CVector_borrowed_Float64 carrier;
    carrier.dims[0] = (int64_t)mxGetNumberOfElements(value);
    carrier.data = (double *)mxGetDoubles(value);
    return carrier;
}

static mxArray *jlw_out_CDict_owned_Float64(CDict_owned_Float64 carrier)
{
    /* Keys are checked before anything is created, so a bad
       one is reported while nothing is held. */
    for (int64_t i = 0; i < carrier.length; i++) {
        if (!jlw_valid_field_name(carrier.keys[i].data, carrier.keys[i].length)) {
            jlw_release_strings(carrier.keys, carrier.length);
            jlw_release(carrier.values);
            mexErrMsgIdAndTxt("jlw:argument",
                "a dictionary key is not a legal MATLAB field name");
        }
    }
    const char **names =
        (const char **)mxMalloc((size_t)(carrier.length ? carrier.length : 1) * sizeof(char *));
    for (int64_t i = 0; i < carrier.length; i++) {
        char *key = (char *)mxMalloc((size_t)carrier.keys[i].length + 1);
        memcpy(key, carrier.keys[i].data, (size_t)carrier.keys[i].length);
        key[carrier.keys[i].length] = '\0';
        names[i] = key;
    }
    mxArray *out = mxCreateStructMatrix(1, 1, (int)carrier.length, names);
    for (int64_t i = 0; i < carrier.length; i++) {
        mxArray *field = mxCreateNumericMatrix(1, 1, mxDOUBLE_CLASS, mxREAL);
        *mxGetDoubles(field) = (double)carrier.values[i];
        mxSetFieldByNumber(out, 0, (int)i, field);
    }
    jlw_release_strings(carrier.keys, carrier.length);
    jlw_release(carrier.values);
    return out;
}

static mxArray *jlw_out_CDict_owned_Int32(CDict_owned_Int32 carrier)
{
    /* Keys are checked before anything is created, so a bad
       one is reported while nothing is held. */
    for (int64_t i = 0; i < carrier.length; i++) {
        if (!jlw_valid_field_name(carrier.keys[i].data, carrier.keys[i].length)) {
            jlw_release_strings(carrier.keys, carrier.length);
            jlw_release(carrier.values);
            mexErrMsgIdAndTxt("jlw:argument",
                "a dictionary key is not a legal MATLAB field name");
        }
    }
    const char **names =
        (const char **)mxMalloc((size_t)(carrier.length ? carrier.length : 1) * sizeof(char *));
    for (int64_t i = 0; i < carrier.length; i++) {
        char *key = (char *)mxMalloc((size_t)carrier.keys[i].length + 1);
        memcpy(key, carrier.keys[i].data, (size_t)carrier.keys[i].length);
        key[carrier.keys[i].length] = '\0';
        names[i] = key;
    }
    mxArray *out = mxCreateStructMatrix(1, 1, (int)carrier.length, names);
    for (int64_t i = 0; i < carrier.length; i++) {
        mxArray *field = mxCreateNumericMatrix(1, 1, mxINT32_CLASS, mxREAL);
        *mxGetInt32s(field) = (int32_t)carrier.values[i];
        mxSetFieldByNumber(out, 0, (int)i, field);
    }
    jlw_release_strings(carrier.keys, carrier.length);
    jlw_release(carrier.values);
    return out;
}

static mxArray *jlw_out_COpt_Float64(COpt_Float64 carrier)
{
    if (carrier.has_value == 0) {
        return mxCreateNumericMatrix(0, 0, mxDOUBLE_CLASS, mxREAL);
    }
    mxArray *out = mxCreateNumericMatrix(1, 1, mxDOUBLE_CLASS, mxREAL);
    *mxGetDoubles(out) = carrier.value;
    return out;
}

static mxArray *jlw_out_CStrArray_owned(CStrArray_owned carrier)
{
    mxArray *out = mxCreateCellMatrix((mwSize)carrier.length, 1);
    for (int64_t i = 0; i < carrier.length; i++) {
        char *text = (char *)mxMalloc((size_t)carrier.data[i].length + 1);
        memcpy(text, carrier.data[i].data, (size_t)carrier.data[i].length);
        text[carrier.data[i].length] = '\0';
        mxSetCell(out, (mwSize)i, mxCreateString(text));
        mxFree(text);
    }
    jlw_release_strings(carrier.data, carrier.length);
    return out;
}

static mxArray *jlw_out_CString_borrowed(CString_borrowed carrier)
{
    /* `mxCreateString` takes a C string, so an embedded NUL
       truncates; Julia permits them. */
    char *text = (char *)mxMalloc((size_t)carrier.length + 1);
    memcpy(text, carrier.data, (size_t)carrier.length);
    text[carrier.length] = '\0';
    mxArray *out = mxCreateString(text);
    mxFree(text);
    return out;
}

static mxArray *jlw_out_CString_owned(CString_owned carrier)
{
    /* `mxCreateString` takes a C string, so an embedded NUL
       truncates; Julia permits them. */
    char *text = (char *)mxMalloc((size_t)carrier.length + 1);
    memcpy(text, carrier.data, (size_t)carrier.length);
    text[carrier.length] = '\0';
    jlw_release(carrier.data);
    mxArray *out = mxCreateString(text);
    mxFree(text);
    return out;
}

static mxArray *jlw_out_CVector_owned_Bool(CVector_owned_Bool carrier)
{
    mwSize shape[2] = {1, 1};
    shape[0] = (mwSize)carrier.dims[0];
    mxArray *out = mxCreateLogicalArray(2, shape);
    memcpy(mxGetLogicals(out), carrier.data,
           mxGetNumberOfElements(out) * sizeof(bool));
    jlw_release(carrier.data);
    return out;
}

static mxArray *jlw_out_CVector_owned_Float64(CVector_owned_Float64 carrier)
{
    mwSize shape[2] = {1, 1};
    shape[0] = (mwSize)carrier.dims[0];
    mxArray *out = mxCreateNumericArray(2, shape, mxDOUBLE_CLASS, mxREAL);
    memcpy(mxGetDoubles(out), carrier.data,
           mxGetNumberOfElements(out) * sizeof(double));
    jlw_release(carrier.data);
    return out;
}

static mxArray *jlw_out_double(double carrier)
{
    mxArray *out = mxCreateNumericMatrix(1, 1, mxDOUBLE_CLASS, mxREAL);
    *mxGetDoubles(out) = carrier;
    return out;
}

static mxArray *jlw_out_int32_t(int32_t carrier)
{
    mxArray *out = mxCreateNumericMatrix(1, 1, mxINT32_CLASS, mxREAL);
    *mxGetInt32s(out) = carrier;
    return out;
}

static mxArray *jlw_out_int64_t(int64_t carrier)
{
    mxArray *out = mxCreateNumericMatrix(1, 1, mxINT64_CLASS, mxREAL);
    *mxGetInt64s(out) = carrier;
    return out;
}
