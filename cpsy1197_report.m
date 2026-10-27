function cpsy1197_report(out, studentName)
% CPSY1197_REPORT  Print the numbers for your 10 November submission.
%
%   cpsy1197_report(out)
%   cpsy1197_report(out, 'Your Name')
%
% Copy the whole block it prints into your submission. These are the numbers
% you are graded on, so read them before you paste them: a rejection rate of
% 40% is not a typo you can ignore.
%
% CPSY 1197, Fall 2026.

if nargin < 2, studentName = '(your name)'; end
L = out.log;

bar = repmat('-', 1, 62);
fprintf('\n%s\n', bar);
fprintf('CPSY 1197  preprocessing summary\n');
fprintf('%s\n', bar);
fprintf('Student          : %s\n', studentName);
fprintf('File             : %s\n', L.file);
if isfield(L, 'experimentTitle')
    fprintf('Experiment       : %s\n', L.experimentTitle);
end
fprintf('Run              : %s\n\n', L.runWhen);

fprintf('Recording\n');
fprintf('  channels       : %d\n',        L.nChansRaw);
fprintf('  sampling rate  : %g Hz\n\n',   L.fsample);

fprintf('Parameters given to you\n');
fprintf('  filter         : %g to %g Hz, %s\n', ...
        L.filter.hp, L.filter.lp, L.filter.type);
fprintf('  resampled to   : %g Hz  (from %g)\n', L.fsample, L.fsampleRaw);
fprintf('  reference      : %s\n', refline(L));
fprintf('  event shift    : %+g ms  (screen delay, ERP CORE)\n', 1000*L.eventShift);
if isfield(L, 'answerWindow')
    fprintf('  trials         : stimuli with a correct answer within %g to %g s\n', ...
            L.answerWindow(1), L.answerWindow(2));
end
fprintf('  epoch          : %g to %g s\n', L.epochWindow(1), L.epochWindow(2));
fprintf('  baseline       : %g to %g s\n\n', L.baselineWindow(1), L.baselineWindow(2));

fprintf('Decisions you made\n');
if isempty(L.badChannels)
    fprintf('  bad channels   : none\n');
else
    fprintf('  bad channels   : %s  (removed, rebuilt after referencing)\n', ...
            strjoin(L.badChannels, ', '));
end
if isempty(L.icaRemoved)
    fprintf('  ICA components : none removed\n');
else
    fprintf('  ICA components : removed %s\n', mat2str(L.icaRemoved));
end
R = L.rejection;
fprintf('  bad trials     : %d marked by hand\n', numel(R.idxByHand));
fprintf('%s', wraplist('                   ', R.idxByHand));
fprintf('\n');
if isfield(L, 'nStimuli')
    fprintf('  stimuli        : %d\n', L.nStimuli);
    fprintf('  trials in      : %d  (%d without a correct answer in time)\n', ...
            L.nTrialsInitial, L.nNoCorrectAnswer);
else
    fprintf('  trials in      : %d\n', L.nTrialsInitial);
end
fprintf('  trials kept    : %d\n',  L.nTrialsFinal);
fprintf('  trials removed : %d  (%.1f%%: %d by the rule, %d by hand)\n', ...
        L.nTrialsRejected, L.pctRejected, L.nRejectedThreshold, L.nRejectedByHand);

fprintf('\nAll %d removed trials, by their number in the epoched data\n', L.nTrialsRejected);
fprintf('  by the rule, peak-to-peak over %g uV (%d)\n', R.thrPeak2Peak, numel(R.idxByRule));
fprintf('%s', wraplist('    ', R.idxByRule));
fprintf('  by hand (%d)\n', numel(R.idxByHand));
fprintf('%s', wraplist('    ', R.idxByHand));

if isfield(L, 'comparison')
    C = L.comparison;
    fprintf('\nWhat the ICA bought you (same rule, one run)\n');
    fprintf('                     without ICA    with ICA\n');
    fprintf('   removed by rule    %3d (%2.0f%%)      %3d (%2.0f%%)\n', ...
            C.rejectedWithoutICA, 100*C.rejectedWithoutICA/C.nTrials, ...
            C.rejectedWithICA,    100*C.rejectedWithICA/C.nTrials);
    fprintf('   recovered                        %d trials\n', C.recovered);
end

if isfield(L, 'nTrialsPerCondition')
    fprintf('\nTrials per condition\n');
    fn = fieldnames(L.nTrialsPerCondition);
    for k = 1:numel(fn)
        fprintf('  %-15s: %d\n', readable(fn{k}), L.nTrialsPerCondition.(fn{k}));
    end
end

notes = {};
if refchanged(L)
    notes{end+1} = sprintf(['NOTE: your reference is not the one everyone else uses, because\n' ...
                            'you marked a reference channel broken. Say why in your log.\n']);
end
if L.pctRejected > 25
    notes{end+1} = sprintf(['NOTE: you removed more than a quarter of your trials. That may be\n' ...
                            'correct, but it needs a sentence of explanation in your log.\n']);
elseif L.pctRejected < 1
    notes{end+1} = sprintf(['NOTE: you removed almost nothing. Check that you actually looked,\n' ...
                            'and say in your log why this participant was so clean.\n']);
end
fprintf('\n%s\n', bar);
if ~isempty(notes)
    fprintf('%s', notes{:});
    fprintf('%s\n', bar);
end
fprintf('\n');
end

% ---------------------------------------------------------------------------
function s = wraplist(prefix, idx)
% Trial numbers on as many lines as they need, each line starting with prefix.
if isempty(idx), s = sprintf('%snone\n', prefix); return; end
s = ''; line = prefix;
for k = 1:numel(idx)
    word = sprintf('%d', idx(k));
    if numel(line) + numel(word) + 1 > 66 && numel(line) > numel(prefix)
        s = [s line sprintf('\n')]; line = prefix; %#ok<AGROW>
    end
    if numel(line) > numel(prefix), line = [line ' ']; end %#ok<AGROW>
    line = [line word]; %#ok<AGROW>
end
s = [s line sprintf('\n')];
end

% ---------------------------------------------------------------------------
function tf = refchanged(L)
wanted = L.referenceRequested;
tf = ~(ischar(wanted) && strcmpi(wanted, 'all')) && ~isequal(cellstr(wanted), cellstr(L.reference));
end

% ---------------------------------------------------------------------------
function s = refline(L)
wanted = L.referenceRequested;
if ischar(wanted) && strcmpi(wanted, 'all')
    s = sprintf('average of %d good EEG channels', numel(L.reference));
elseif refchanged(L)
    lost = setdiff(cellstr(wanted), cellstr(L.reference), 'stable');
    s = sprintf('%s ALONE  (%s marked broken)', strjoin(cellstr(L.reference), ' + '), ...
                strjoin(lost, ', '));
else
    s = strjoin(cellstr(L.reference), ' + ');
end
end

% ---------------------------------------------------------------------------
function s = readable(name)
% A condition's name as people write it: scrambledFaces as "scrambled faces".
s = lower(regexprep(name, '([a-z])([A-Z])', '$1 $2'));
end
