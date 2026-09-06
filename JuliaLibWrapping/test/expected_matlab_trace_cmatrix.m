function out = trace_cmatrix(m)
%TRACE_CMATRIX
%
%   Array arguments are passed without copying. If this function
%   writes to one, every variable sharing that data changes with
%   it. Rebuild with duplicate_arguments = true if it does.
    arguments
        m double
    end
    if ndims(m) > 2
        error("demo:trace_cmatrix", "m must have at most 2 dimensions.");
    end
    out = libdemo_mex('trace_cmatrix', m);
end
