function out = greeting_length(s)
    arguments
        s (1,1) string
    end
    out = libdemo_mex('greeting_length', convertStringsToChars(s));
end
