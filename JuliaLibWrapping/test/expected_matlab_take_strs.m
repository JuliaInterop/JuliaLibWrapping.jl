function out = take_strs(a)
    arguments
        a 
    end
    out = libdemo_mex('take_strs', cellstr(a));
end
