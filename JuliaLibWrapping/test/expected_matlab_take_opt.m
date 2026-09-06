function out = take_opt(o)
    arguments
        o (:,:) double
    end
    if ~isempty(o) && ~isscalar(o)
        error("demo:take_opt", "o must be a scalar or [].");
    end
    out = libdemo_mex('take_opt', o);
end
