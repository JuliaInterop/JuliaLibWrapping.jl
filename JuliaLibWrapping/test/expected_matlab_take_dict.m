function out = take_dict(d)
    arguments
        d (1,1) struct
    end
    out = libdemo_mex('take_dict', d);
end
