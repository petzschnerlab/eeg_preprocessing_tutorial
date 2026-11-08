function ga = cpsy1197_average_across(where, params)
% CPSY1197_AVERAGE_ACROSS  Average the ERPs of several participants: the grand average.
%
%   ga = cpsy1197_average_across('data')
%   ga = cpsy1197_average_across('data', struct('negativeUp', true))
%
% This is the second averaging step. cpsy1197_average_within has already
% averaged the trials of each person (the *_erp.mat files, one per person).
% Here every person counts once: the grand average of a condition is the
% mean of the participants' ERPs, no matter how many trials each of them
% has. The grand average of the difference wave is the mean of the
% participants' difference waves.
%
% It draws three figures. (1) The component's channel, the two conditions
% and the difference wave, with the standard error across participants as a
% band around each curve. (2) All channels laid out on the head. (3) The
% scalp topography of both conditions and the difference in the time
% window of the component. It prints the mean amplitude in that window and
% saves grandavg_<experiment>.mat (the variable ga) and the figures in
% the data folder.
%
% Only participants of ONE experiment can be averaged together. A
% participant with fewer than params.minTrials trials in one of the two
% conditions is left out, and the printout says so. A participant that
% appears twice is used once.
%
% params (all optional)
%   experiment  'P3b', 'N170' or 'N400'. Needed only if your folder holds more than one.
%   minTrials   fewest trials per condition a participant needs. Default 10.
%   negativeUp  true draws negative voltages upward, as in much of the ERP literature. Default false.
%   channel     channel for figure 1 and the amplitudes. Default: ERP CORE's (Pz, PO8, CPz).
%   window      time window in seconds for the amplitudes and figure 3. Default: ERP CORE's.
%   layout      electrode layout file. Default: easycapM1 of FieldTrip.
%   save        false: do not write the .mat file and the figures. Default true.
%
% See also FT_TIMELOCKGRANDAVERAGE, FT_MULTIPLOTER, FT_TOPOPLOTER, CPSY1197_AVERAGE_WITHIN

if nargin < 1, where  = 'data'; end
if nargin < 2, params = struct(); end
p.experiment = ft_getopt(params, 'experiment', '');
p.minTrials  = ft_getopt(params, 'minTrials',  10);
p.negativeUp = ft_getopt(params, 'negativeUp', false);
p.channel    = ft_getopt(params, 'channel',    '');
p.window     = ft_getopt(params, 'window',     []);
p.layout     = ft_getopt(params, 'layout',     fullfile(fileparts(which('ft_defaults')), 'template', 'layout', 'easycapM1.mat'));
p.save       = ft_getopt(params, 'save',       true);

% A quieter FieldTrip, as in cpsy1197_preprocess. Your own settings come
% back when this function ends.
global ft_default %#ok<GVMIS> FieldTrip keeps its defaults in this global
ftBefore  = ft_default;
ftRestore = onCleanup(@() restoreft(ftBefore));
ft_default.showcallinfo = 'no';
ft_default.trackusage   = false;
ft_defaults;
ft_info off; ft_notice off;

%% ------------------------------------------------------------ FIND THE FILES
if ~isfolder(where)
    error('cpsy1197:average:nofolder', 'Cannot find the folder "%s".', where);
end
d     = dir(fullfile(where, '**', '*_erp.mat'));
files = sort(arrayfun(@(x) fullfile(x.folder, x.name), d, 'UniformOutput', false));
if isempty(files)
    error('cpsy1197:average:nofile', 'No *_erp.mat files in "%s". Run cpsy1197_average_within first.', where);
end
E = cell(size(files));
for f = 1:numel(files)
    s = load(files{f}, 'erp');
    E{f} = s.erp;
end
expts = unique(cellfun(@(e) e.experiment, E, 'UniformOutput', false));
if isempty(p.experiment)
    if numel(expts) > 1
        error('cpsy1197:average:mixed', ['The folder holds more than one experiment (%s). Never average across experiments.\n' ...
              'Choose one: cpsy1197_average_across(''%s'', struct(''experiment'', ''%s''))'], strjoin(expts, ', '), where, expts{1});
    end
    p.experiment = expts{1};
end
sel   = cellfun(@(e) strcmp(e.experiment, p.experiment), E);
E     = E(sel);
files = files(sel);
fprintf('\n=== CPSY 1197 averaging across participants: %s ===\n', p.experiment);

%% ----------------------------------------- WHO GOES IN, WHO STAYS OUT, AND WHY
m = E{1}.measure;                          % conditions, channel and window of this experiment
if isempty(p.channel), p.channel = m.channel; end
if isempty(p.window),  p.window  = m.window;  end
c1 = m.first; c2 = m.second;

keep = true(size(E)); excluded = struct('subject', {}, 'reason', {});
seen = [];
for k = 1:numel(E)
    e = E{k};
    if ismember(e.subject, seen)
        fprintf('  Participant %d appears twice (%s). The first file is used, this one is skipped.\n', e.subject, files{k});
        keep(k) = false; continue
    end
    seen(end+1) = e.subject; %#ok<AGROW>
    n1 = e.nTrials.(c1); n2 = e.nTrials.(c2);
    if min(n1, n2) < p.minTrials
        why = sprintf('only %d %s and %d %s trials, fewer than %d', n1, c1, n2, c2, p.minTrials);
        fprintf('  Participant %d left out: %s.\n', e.subject, why);
        excluded(end+1) = struct('subject', e.subject, 'reason', why); %#ok<AGROW>
        keep(k) = false;
    end
end
E = E(keep);
[~, ord] = sort(cellfun(@(e) e.subject, E)); E = E(ord);
N = numel(E);
if N < 2
    error('cpsy1197:average:fewparticipants', 'Need at least 2 participants for a grand average, have %d.', N);
end
subjects = cellfun(@(e) e.subject, E);
subjects = subjects(:)';
fprintf('  %d participants averaged: %s\n', N, mat2str(subjects));

% every ERP must have the same channels in the same order and the same time axis
for k = 2:N
    if ~isequal(E{k}.cond.(c1).label, E{1}.cond.(c1).label)
        error('cpsy1197:average:labels', 'Participant %d has other channels than participant %d.', E{k}.subject, E{1}.subject);
    end
    if numel(E{k}.cond.(c1).time) ~= numel(E{1}.cond.(c1).time) || ...
       max(abs(E{k}.cond.(c1).time - E{1}.cond.(c1).time)) > 1e-6
        error('cpsy1197:average:time', 'Participant %d has another time axis than participant %d.', E{k}.subject, E{1}.subject);
    end
end

%% ----------------------------------------------------------- GRAND AVERAGES
% ft_timelockgrandaverage with method 'across' (the default) takes one input
% per participant and weights them equally. Called once without and once
% with keepindividual: the first gives avg, var and dof, the second keeps
% every participant's own ERP (participants x channels x time).
getc = @(name) cellfun(@(e) e.cond.(name), E, 'UniformOutput', false);
in   = struct(c1, {getc(c1)}, c2, {getc(c2)}, 'diff', {cellfun(@(e) e.diff, E, 'UniformOutput', false)});
names = {c1, c2, 'diff'};
ga = struct('experiment', p.experiment, 'subjects', subjects, 'excluded', excluded, 'measure', m, ...
            'channel', p.channel, 'window', p.window, 'cond', struct(), 'individual', struct());
for k = 1:numel(names)
    cfg = []; cfg.method = 'across'; cfg.parameter = 'avg';
    cfg.keepindividual = 'no';
    g = ft_timelockgrandaverage(cfg, in.(names{k}){:});
    cfg.keepindividual = 'yes';
    i = ft_timelockgrandaverage(cfg, in.(names{k}){:});
    if strcmp(names{k}, 'diff'), ga.diff = g; else, ga.cond.(names{k}) = g; end
    ga.individual.(names{k}) = i;
end

%% ----------------------------------------------- MEAN AMPLITUDE IN THE WINDOW
% one number per participant: the mean over the window at the channel
t    = ga.diff.time;
ci   = find(strcmp(ga.diff.label, p.channel));
if isempty(ci), error('cpsy1197:average:channel', 'There is no channel "%s".', p.channel); end
tw   = t >= p.window(1) & t <= p.window(2);
amp  = nan(N, 3);
for k = 1:3
    amp(:,k) = mean(squeeze(ga.individual.(names{k}).individual(:, ci, tw)), 2);
end
ga.amplitude = array2table(amp, 'VariableNames', {c1, c2, 'difference'}, ...
                           'RowNames', arrayfun(@num2str, subjects(:), 'UniformOutput', false));
fprintf('\nMean amplitude at %s, %d to %d ms (uV), mean and standard error over %d participants:\n', ...
        p.channel, round(p.window(1)*1000), round(p.window(2)*1000), N);
for k = 1:3
    fprintf('  %-12s %7.2f  (SE %.2f)\n', ga.amplitude.Properties.VariableNames{k}, ...
            mean(amp(:,k)), std(amp(:,k)) / sqrt(N));
end

%% ---------------------------------------------------------------- THE FIGURES
% 1. The channel of the component, with the standard error as a band.
% The standard error is the standard deviation across participants over
% sqrt(N). ft_singleplotER draws no bands, so this figure is plain MATLAB.
f1 = figure('Name', 'Grand average', 'Color', 'w', 'Position', [100 100 760 640]);
tms = t * 1000;
col = [0.00 0.45 0.74; 0.85 0.33 0.10; 0.15 0.15 0.15];
ax1 = subplot(2, 1, 1); hold on;
for k = 1:2
    g = ga.cond.(names{k});
    band(tms, g.avg(ci,:), sqrt(g.var(ci,:) ./ g.dof(ci,:)), col(k,:));
end
legend(ax1, names(1:2), 'Location', 'best', 'Box', 'off');
decorate(ax1, sprintf('%s, %s: both conditions (N = %d)', p.experiment, p.channel, N), p);
ax2 = subplot(2, 1, 2); hold on;
g = ga.diff;
band(tms, g.avg(ci,:), sqrt(g.var(ci,:) ./ g.dof(ci,:)), col(3,:));
decorate(ax2, sprintf('difference: %s minus %s (grey: the window that is measured)', c1, c2), p);
yl = get(ax2, 'YLim');
fill(ax2, p.window([1 2 2 1])*1000, yl([1 1 2 2]), [0.5 0.5 0.5], 'FaceAlpha', 0.15, ...
     'EdgeColor', 'none', 'HandleVisibility', 'off');
xlabel(ax2, 'time (ms)');

% 2. All channels on the head. Positive is up, the FieldTrip default.
cfg = []; cfg.layout = p.layout; cfg.showlabels = 'yes'; cfg.showoutline = 'yes'; cfg.xlim = [-0.2 0.8];
cfg.linecolor = col(1:2,:); cfg.comment = 'no'; cfg.showcomment = 'no';
f2 = figure('Name', 'All channels', 'Color', 'w');
ft_multiplotER(cfg, ga.cond.(c1), ga.cond.(c2));
title(sprintf('%s: %s (blue) and %s (orange), N = %d', p.experiment, c1, c2, N));

% 3. The topography in the window, both conditions on one colour scale
f3 = figure('Name', 'Topography', 'Color', 'w', 'Position', [100 100 1000 340]);
win = ga.cond.(c1).time >= p.window(1) & ga.cond.(c1).time <= p.window(2);
zc  = max(abs([mean(ga.cond.(c1).avg(:,win), 2); mean(ga.cond.(c2).avg(:,win), 2)]));
zd  = max(abs(mean(ga.diff.avg(:,win), 2)));
src = {ga.cond.(c1), ga.cond.(c2), ga.diff};
ttl = {c1, c2, [c1 ' minus ' c2]};
zl  = {[-zc zc], [-zc zc], [-zd zd]};
for k = 1:3
    subplot(1, 3, k);
    cfg = []; cfg.layout = p.layout; cfg.xlim = p.window; cfg.zlim = zl{k};
    cfg.figure = 'gca'; cfg.colorbar = 'yes'; cfg.comment = 'no';
    ft_topoplotER(cfg, src{k});
    title(sprintf('%s\n%d to %d ms (uV)', ttl{k}, round(p.window(1)*1000), round(p.window(2)*1000)));
end

%% ------------------------------------------------------------------- SAVING
if p.save
    base = fullfile(where, ['grandavg_' p.experiment]);
    save([base '.mat'], 'ga');
    exportgraphics(f1, [base '_channel.png'], 'Resolution', 150);
    exportgraphics(f2, [base '_allchannels.png'], 'Resolution', 150);
    exportgraphics(f3, [base '_topography.png'], 'Resolution', 150);
    fprintf('\nSaved %s.mat and three figures next to it.\n', base);
end
fprintf('\n');
end

% ---------------------------------------------------------------------------
function restoreft(before)
global ft_default %#ok<GVMIS>
ft_default = before;
ft_info on; ft_notice on;
end

% ---------------------------------------------------------------------------
function band(tms, m, se, col)
% mean curve with a shaded band of one standard error
m = m(:)'; se = se(:)';
fill([tms fliplr(tms)], [m + se fliplr(m - se)], col, 'FaceAlpha', 0.2, 'EdgeColor', 'none', ...
     'HandleVisibility', 'off');
plot(tms, m, 'Color', col, 'LineWidth', 1.8);
end

% ---------------------------------------------------------------------------
function decorate(ax, ttl, p)
% axes, zero lines, labels, polarity
set(ax, 'Box', 'off', 'TickDir', 'out', 'XLim', [-200 800]);
xline(ax, 0, 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
yline(ax, 0, 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
ylabel(ax, 'uV'); title(ax, ttl, 'FontWeight', 'normal');
if p.negativeUp, set(ax, 'YDir', 'reverse'); end
end
