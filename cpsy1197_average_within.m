function erp = cpsy1197_average_within(where)
% CPSY1197_AVERAGE_WITHIN  Average the trials of ONE participant, per condition.
%
%   cpsy1197_average_within('data')                    every participant in data/
%   cpsy1197_average_within('data/12/12_N400_clean.mat')   one participant
%
% This is the first of two averaging steps. Here the trials of one person
% are averaged into that person's ERP, one per condition, and the
% difference wave of the experiment is formed (P3b: target minus standard,
% N170: faces minus cars, N400: unrelated minus related). The second step,
% cpsy1197_average_across, then averages these ERPs across people.
%
% What goes in: the *_clean.mat files that cpsy1197_preprocess saved next to
% your raw data. What comes out: one *_erp.mat file next to each of them, for
% example data/12/12_N400_erp.mat, and the variable erp.
%
% The averaging is ft_timelockanalysis, called once per condition with
% cfg.trials listing the trials of that condition. The difference is
% ft_math with operation 'subtract'. The result is checked against the
% averages the pipeline already saved: they must agree.
%
% See also FT_TIMELOCKANALYSIS, FT_MATH, CPSY1197_PREPROCESS, CPSY1197_AVERAGE_ACROSS

if nargin < 1, where = 'data'; end

% A quieter FieldTrip, as in cpsy1197_preprocess: no "the call to ... took"
% lines, no usage tracker, no "the input is raw data" notes. Your own
% settings come back when this function ends.
global ft_default %#ok<GVMIS> FieldTrip keeps its defaults in this global
ftBefore  = ft_default;
ftRestore = onCleanup(@() restoreft(ftBefore));
ft_default.showcallinfo = 'no';
ft_default.trackusage   = false;
ft_defaults;
ft_info off; ft_notice off;

%% ------------------------------------------------------------ FIND THE FILES
if isfolder(where)
    d     = dir(fullfile(where, '**', '*_clean.mat'));
    files = arrayfun(@(x) fullfile(x.folder, x.name), d, 'UniformOutput', false);
elseif isfile(where)
    files = {where};
else
    error('cpsy1197:average:nofile', 'Cannot find "%s". Give a data folder or one *_clean.mat file.', where);
end
if isempty(files)
    error('cpsy1197:average:nofile', 'No *_clean.mat files in "%s". Run cpsy1197_preprocess first.', where);
end
% in the order of the participant numbers: 2, 3, ..., 12 and not 12 before 2
num = cellfun(@(x) str2double(regexp(x, '(\d+)_[A-Za-z0-9]+_clean\.mat$', 'tokens', 'once')), files, 'UniformOutput', false);
num(cellfun(@isempty, num)) = {Inf};
[~, ord] = sort(cell2mat(num)); files = files(ord);
fprintf('\n=== CPSY 1197 averaging within participants ===\n%d participant file(s)\n', numel(files));

%% -------------------------------------------------- WHAT IS MEASURED WHERE
% The difference wave and where ERP CORE measures it (Kappenman et al., 2021):
% the channel and the time window of the component.
M = struct();
M.P3b  = struct('first','target',    'second','standard', 'channel','Pz',  'window',[0.300 0.600]);
M.N170 = struct('first','faces',     'second','cars',      'channel','PO8', 'window',[0.110 0.150]);
M.N400 = struct('first','unrelated', 'second','related',   'channel','CPz', 'window',[0.300 0.500]);

%% ------------------------------------------------------- ONE FILE AT A TIME
for f = 1:numel(files)
    s    = load(files{f}, 'data', 'log', 'avg');
    log  = s.log;
    expt = log.experiment;                % P3b, N170 or N400, as the pipeline wrote it into the log
    if ~isfield(M, expt)
        error('cpsy1197:average:experiment', '%s: unknown experiment "%s".', files{f}, expt);
    end
    m     = M.(expt);
    conds = log.params.conditions;
    names = fieldnames(conds);
    eeg   = log.channels;                 % the 30 EEG channels, without the eye channels
    sub   = regexp(files{f}, '(\d+)_[A-Za-z0-9]+_clean\.mat$', 'tokens', 'once');

    erp = struct('experiment', expt, 'subject', str2double(sub{1}), ...
                 'file', files{f}, 'measure', m, 'nTrials', struct(), 'cond', struct());

    for k = 1:numel(names)
        cn  = names{k};
        idx = find(ismember(s.data.trialinfo(:,1), conds.(cn)));
        erp.nTrials.(cn) = numel(idx);
        if isempty(idx), continue; end

        cfg          = [];
        cfg.trials   = idx;               % only the trials of this condition
        cfg.channel  = eeg;
        tl           = ft_timelockanalysis(cfg, s.data);   % avg, var, dof, time, label
        erp.cond.(cn) = tl;

        % check against the average the pipeline saved (stored as single)
        if isfield(s.avg, cn)
            dev = max(abs(double(s.avg.(cn).avg(:)) - tl.avg(:)));
            if dev > 1e-3
                error('cpsy1197:average:mismatch', ...
                      '%s, %s: this average differs from the one in the file by %g uV.', files{f}, cn, dev);
            end
        end
    end

    % the difference wave, first minus second, formed here for this person
    if isfield(erp.cond, m.first) && isfield(erp.cond, m.second)
        cfg           = [];
        cfg.parameter = 'avg';
        cfg.operation = 'subtract';
        erp.diff      = ft_math(cfg, erp.cond.(m.first), erp.cond.(m.second));
    else
        erp.diff = [];
        warning('cpsy1197:average:nodiff', 'Participant %d has no trials in one of the two conditions, no difference wave.', erp.subject);
    end

    [fdir, fbase] = fileparts(files{f});
    outFile = fullfile(fdir, [regexprep(fbase, '_clean$', '') '_erp.mat']);
    save(outFile, 'erp');
    [~, outName, outExt] = fileparts(outFile);
    fprintf('  %-4d %-5s %-34s -> saved %s\n', erp.subject, expt, trialcounts(erp.nTrials), [outName outExt]);
end
if ~isfolder(where), where = 'data'; end
fprintf('\nThe files are next to your *_clean.mat files. Next: cpsy1197_average_across(''%s'')\n\n', where);
end

% ---------------------------------------------------------------------------
function restoreft(before)
global ft_default %#ok<GVMIS>
ft_default = before;
ft_info on; ft_notice on;
end

% ---------------------------------------------------------------------------
function txt = trialcounts(n)
% "target 38, standard 152" for the printout
c = fieldnames(n); parts = cell(1, numel(c));
for k = 1:numel(c), parts{k} = sprintf('%s %d', c{k}, n.(c{k})); end
txt = strjoin(parts, ', ');
end
