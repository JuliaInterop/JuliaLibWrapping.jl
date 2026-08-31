# API reference

This reference lists the public APIs of the wrapper generator and its ABI
carrier package. For task-oriented use, start with [Your first wrapper](@ref),
[Declaring an API with `@api`](@ref), or [Building and distributing a
library](@ref).

## JuliaLibWrapping

```@meta
CurrentModule = JuliaLibWrapping
```

```@docs
standard_build
build_library
write_wrapper
AbstractTarget
CTarget
PythonTarget
ABIInfo
read_abi_info
parse_abi_info
```

## JLWInterop

```@meta
CurrentModule = JLWInterop
```

```@docs
JLWInterop
@api
@export_release_entrypoints
JLWStatus
JLWResult
jlw_ok
jlw_error
JLW_MESSAGE_BYTES
CArray
CVector
CMatrix
CString
CStrArray
CDict
COpt
Base.get(::COpt, ::Any)
CDICT_VALUE_TYPES
carrier_type
carrier_return_type
to_carrier
to_carrier_as
from_carrier
ApiEntry
api_entries
write_metadata
```
