function cpsy1197_check(dataFolder)
% CPSY1197_CHECK  One command that tells you whether you are ready to start.
%
%   cpsy1197_check
%   cpsy1197_check('data')
%
% Checks that FieldTrip is on the path and initialised, that this folder
% contains the pipeline functions, and that your data folder contains at
% least one raw ERP CORE recording, and lists which experiments they are
% from (N170, P3b, N400). Prints READY if everything is in place, and
% otherwise tells you exactly what is missing and what to do about it.
%
% CPSY 1197, Fall 2026.

if nargin < 1, dataFolder = 'data'; end
ok = true;

% --- 1. FieldTrip on the path?
if isempty(which('ft_defaults'))
    fprintf(['\nMISSING: FieldTrip is not on your MATLAB path.\n' ...
             'Fix: addpath(''<the folder where you unzipped fieldtrip>'')\n' ...
             'then run this check again.\n']);
    ok = false;
else
    ft_defaults;
    [ftver, ftpath] = ft_version;
    fprintf('\nFieldTrip found: version %s\n  at %s\n', ftver, ftpath);
    if ~strcmp(ftver, '20260812')
        fprintf(['NOTE: the course was tested with FieldTrip 20260812. Yours will\n' ...
                 'probably work; if something breaks, say which version you have.\n']);
    end
    % The electrode positions that rebuild removed channels and draw the
    % topographies come with FieldTrip.
    elecfile = fullfile(ftpath, 'template', 'electrode', 'standard_1020.elc');
    if ~exist(elecfile, 'file')
        fprintf(['MISSING: %s\n' ...
                 'Your FieldTrip copy is incomplete. Download it again, unzip the\n' ...
                 'whole archive, and point addpath at the new folder.\n'], elecfile);
        ok = false;
    end
end

% --- 2. The two pipeline functions next to this file?
for f = {'cpsy1197_preprocess', 'cpsy1197_report'}
    if isempty(which(f{1}))
        fprintf(['MISSING: %s.m is not on the path. Put it in the same folder\n' ...
                 'as this check and cd into that folder.\n'], f{1});
        ok = false;
    end
end

% --- 3. Can FieldTrip actually read an EEGLAB .set? (needs its eeglab module)
if ok && isempty(which('ft_read_header'))
    fprintf('MISSING: ft_read_header not found. Your FieldTrip copy may be incomplete.\n');
    ok = false;
end

% --- 4. Data folder with at least one recording, and from which experiments?
% ERP CORE names every raw recording after its experiment: 12_P3.set,
% 12_N170.set, 12_N400.set. The pipeline reads the experiment from that name.
experiments = {'P3', 'P3b'; 'N170', 'N170'; 'N400', 'N400'};   % file tag, name
if ~exist(dataFolder, 'dir')
    fprintf(['MISSING: no folder called "%s" here. Create it and copy your\n' ...
             'assigned participants into it, one subfolder per participant,\n' ...
             'for example %s%s12%s12_N170.set\n'], dataFolder, dataFolder, filesep, filesep);
    ok = false;
else
    hits = cell(size(experiments, 1), 1);
    for e = 1:size(experiments, 1)
        pattern = ['*_' experiments{e,1} '.set'];
        % also accept .set files placed directly in the data folder
        hits{e} = [dir(fullfile(dataFolder, '*', pattern)); dir(fullfile(dataFolder, pattern))];
    end
    nAll = sum(cellfun(@numel, hits));
    if nAll == 0
        fprintf(['MISSING: the folder "%s" exists but contains no raw recording\n' ...
                 '(a file like 12_P3.set, 12_N170.set or 12_N400.set).\n' ...
                 'Copy BOTH files of each participant, the .set and the .fdt.\n'], dataFolder);
        ok = false;
    else
        fprintf('Data found: %d recording(s) in "%s"\n', nAll, dataFolder);
        for e = 1:size(experiments, 1)
            h = hits{e};
            if isempty(h), continue; end
            ids = regexp({h.name}, '^(\d+)_', 'tokens', 'once');
            ids = sort(str2double([ids{:}]));
            if isscalar(ids), word = 'participant'; else, word = 'participants'; end
            fprintf('  %-5s %3d   %s %s\n', experiments{e,2}, numel(h), word, ...
                    strtrim(sprintf('%d ', ids)));
            for k = 1:numel(h)
                fdt = strrep(fullfile(h(k).folder, h(k).name), '.set', '.fdt');
                if ~exist(fdt, 'file')
                    fprintf(['PROBLEM: %s has no matching .fdt file next to it.\n' ...
                             'The .set is only the header; the voltages are in the .fdt.\n'], h(k).name);
                    ok = false;
                end
            end
        end
    end
end

% --- verdict
if ok
    fprintf('\nREADY. Start with the tutorial, section 2.\n\n');
else
    fprintf('\nNOT READY. Fix the lines marked MISSING or PROBLEM above, then rerun.\n\n');
end
end
