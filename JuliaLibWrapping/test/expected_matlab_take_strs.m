function out = take_strs(a)
    arguments
        a (1,:) cell
    end
    out = libdemo_mex('take_strs', a);
end
