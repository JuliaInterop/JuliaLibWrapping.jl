function out = sum3d(a)
    arguments
        a double
    end
    if ndims(a) > 3
        error("demo:sum3d", "a must have at most 3 dimensions.");
    end
    out = libdemo_mex('sum3d', a);
end
