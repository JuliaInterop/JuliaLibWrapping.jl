function build_mex(library_dir)
%BUILD_MEX  Compile the ctuple_demo gateway.
%   BUILD_MEX() expects the shared library in this directory.
%   BUILD_MEX(DIR) takes it from DIR instead. The path is compiled
%   in; set LIBCTUPLE_MEX_LIBRARY to override it at run time.
    here = fileparts(mfilename('fullpath'));
    if nargin < 1
        library_dir = here;
    end
    target = fullfile(here, '+ctuple_demo', 'private');
    if ~isfolder(target)
        mkdir(target);
    end
    % The library stays where it was built, next to the runtime its
    % RUNPATH points at, so the path is compiled in instead of
    % copying the library beside the MEX file.
    stem = fullfile(library_dir, 'libctuple');
    % -R2018a selects the typed accessors the gateway uses.
    mex('-R2018a', ...
        '-outdir', target, ...
        ['-I' here], ...
        ['-DJLW_LIBRARY_PATH="' stem '"'], ...
        fullfile(here, 'libctuple_mex.c'));
end
