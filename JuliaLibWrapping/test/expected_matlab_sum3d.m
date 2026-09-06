function out = sum3d(a)
%SUM3D
%
%   Array arguments are passed without copying. If this function
%   writes to one, every variable sharing that data changes with
%   it. Rebuild with duplicate_arguments = true if it does.
    arguments
        a double
    end
    if ndims(a) > 3
        error("demo:sum3d", "a must have at most 3 dimensions.");
    end
    out = libdemo_mex('sum3d', a);
end
