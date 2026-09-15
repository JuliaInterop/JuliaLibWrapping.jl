function out = trace_cmatrix(m)
    arguments
        m double
    end
    if ndims(m) > 2
        error("jlw:dimension", "m must have at most 2 dimensions.");
    end
    out = libdemo_mex('trace_cmatrix', m);
end
