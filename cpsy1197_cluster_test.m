function stat = cpsy1197_cluster_test(where, params)
% CPSY1197_CLUSTER_TEST  Test whether two conditions differ: a cluster-based permutation test.
%
%   stat = cpsy1197_cluster_test('data')
%   stat = cpsy1197_cluster_test('data', struct('analysis', 'full'))
%
% This is the step after cpsy1197_average_across. It reads the grand
% average it saved (grandavg_<experiment>.mat) and asks one question: do
% the two conditions differ (P3b target vs standard, N170 faces vs cars,
% N400 unrelated vs related)?
%
% How it works (Maris and Oostenveld 2007, FieldTrip's ft_timelockstatistics):
%   1. For every channel and time point a paired t-test compares the two
%      conditions across participants.
%   2. Points whose t passes p < 0.05 are kept, and neighbouring points (next
%      in time, or on neighbouring channels) are joined into clusters. The
%      t-values in a cluster are summed.
%   3. The labels of the two conditions are swapped at random within each
%      participant, many times, and step 1 and 2 are repeated. The largest
%      cluster of every swap gives the distribution you expect if the
%      conditions do not differ.
%   4. The p-value is the share of swaps whose largest cluster is at least
%      as strong as the one in your data.
% One test for all channels and time points, so there is no multiple
% comparisons problem.
%
% What the result says, and what it does not. A p below 0.05 means: the two
% conditions differ. It does NOT say when the effect starts or ends, or on
% which channels it is. Where a cluster lies depends on the threshold, the
% noise and the channels, so it only describes where the difference was
% strongest in these data.
%
% Two analyses
%   'window'  (default) all channels, only the time window of the component
%             (ERP CORE's, chosen before looking at the data). The
%             sensitive test of the question you came with.
%   'full'    all channels, 0 to 800 ms. Exploratory: is there a difference
%             anywhere? Less sensitive, because it covers much more.
%
% It draws one figure with four panels: the ERPs at the component's
% channel with the cluster times, where the p-value comes from (the
% largest cluster of every swap against the clusters in your data), the
% t-values for every channel and time point with the clusters outlined, and
% scalp maps of the t-values with the cluster channels marked. It saves
% clusterstat_<experiment>_<analysis>.mat (the variable stat) and .png in
% the data folder.
%
% It works for every experiment and any number of participants from 2 on.
% With fewer than 6 there are too few ways to swap the conditions for a p
% below 0.05; the test still runs, and says so.
%
% params (all optional)
%   experiment        'P3b', 'N170' or 'N400'. If the folder holds more than one and you give none, you are asked.
%   analysis          'window' (default) or 'full'.
%   latency           [start end] in seconds, instead of the window of the analysis.
%   subjects          participant numbers to use, a subset of those in the grand average. Default: all.
%   numrandomization  number of random swaps. Default: every possible swap if
%                     there are at most 5000 of them (10 participants: 1024), else 5000.
%   clusteralpha      threshold for a point to join a cluster. Default 0.05.
%   alpha             threshold for the test. Default 0.05 (two-sided).
%   minnbchan         a point joins a cluster only if at least this many neighbouring
%                     channels pass the threshold too. Default 2.
%   seed              start of the random number generator, so a rerun gives the same p. Default 42.
%   negativeUp        true draws negative voltages upward in the ERP panel. Default false.
%   layout            electrode layout file. Default: easycapM1 of FieldTrip.
%   save              false: do not write the .mat and .png file. Default true.
%   show              false: do not show the figure on screen (it is still saved).
%                     Default true, false when MATLAB runs with -batch.
%
% See also FT_TIMELOCKSTATISTICS, FT_PREPARE_NEIGHBOURS, CPSY1197_AVERAGE_ACROSS

if nargin < 1, where  = 'data'; end
if nargin < 2, params = struct(); end
if isempty(which('ft_defaults'))
    error(['FieldTrip is not on your MATLAB path. Run addpath with your ' ...
           'FieldTrip folder, then cpsy1197_check.']);
end

% A quieter FieldTrip, as in cpsy1197_preprocess. Your own settings come
% back when this function ends.
global ft_default %#ok<GVMIS> FieldTrip keeps its defaults in this global
ftBefore  = ft_default;
ftRestore = onCleanup(@() restoreft(ftBefore));
ft_default.showcallinfo = 'no';
ft_default.trackusage   = false;
ft_defaults;
ft_info off; ft_notice off;

p.experiment       = ft_getopt(params, 'experiment',       '');
p.analysis         = ft_getopt(params, 'analysis',         'window');
p.latency          = ft_getopt(params, 'latency',          []);
p.subjects         = ft_getopt(params, 'subjects',         []);
p.numrandomization = ft_getopt(params, 'numrandomization', []);
p.clusteralpha     = ft_getopt(params, 'clusteralpha',     0.05);
p.alpha            = ft_getopt(params, 'alpha',            0.05);
p.minnbchan        = ft_getopt(params, 'minnbchan',        2);
p.seed             = ft_getopt(params, 'seed',             42);
p.negativeUp       = ft_getopt(params, 'negativeUp',       false);
p.layout           = ft_getopt(params, 'layout',           fullfile(fileparts(which('ft_defaults')), 'template', 'layout', 'easycapM1.mat'));
p.save             = ft_getopt(params, 'save',             true);
p.show             = ft_getopt(params, 'show',             ~batchStartupOptionUsed);
if ~ismember(p.analysis, {'window', 'full'})
    error('cpsy1197:cluster:analysis', 'analysis must be ''window'' or ''full'', not "%s".', p.analysis);
end

%% ------------------------------------------------------- FIND THE GRAND AVERAGE
if ~isfolder(where)
    error('cpsy1197:cluster:nofolder', 'Cannot find the folder "%s".', where);
end
d = dir(fullfile(where, 'grandavg_*.mat'));
d = d(~startsWith({d.name}, '._'));
if isempty(d)
    error('cpsy1197:cluster:nofile', 'No grandavg_*.mat in "%s". Run cpsy1197_average_across first.', where);
end
expts = regexprep({d.name}, '^grandavg_(.*)\.mat$', '$1');
if isempty(p.experiment)
    if numel(expts) > 1
        if batchStartupOptionUsed
            error('cpsy1197:cluster:mixed', ['The folder holds grand averages of more than one experiment (%s).\n' ...
                  'Choose one: cpsy1197_cluster_test(''%s'', struct(''experiment'', ''%s''))'], strjoin(expts, ', '), where, expts{1});
        end
        fprintf('\nThe folder holds grand averages of more than one experiment.\n');
        for k = 1:numel(expts), fprintf('  %d  %s\n', k, expts{k}); end
        choice = [];
        while ~(isscalar(choice) && ismember(choice, 1:numel(expts)))
            choice = input(sprintf('Which one? Type 1 to %d, or 0 to stop: ', numel(expts)));
            if isequal(choice, 0), error('cpsy1197:cluster:cancelled', 'Stopped, no experiment chosen.'); end
        end
        p.experiment = expts{choice};
    else
        p.experiment = expts{1};
    end
end
f = fullfile(where, ['grandavg_' p.experiment '.mat']);
if ~isfile(f)
    error('cpsy1197:cluster:noexperiment', 'There is no %s. Run cpsy1197_average_across for %s first.', f, p.experiment);
end
s  = load(f, 'ga'); ga = s.ga;
m  = ga.measure; c1 = m.first; c2 = m.second;

%% ------------------------------------------------------------- PARTICIPANTS
sel = true(size(ga.subjects));
if ~isempty(p.subjects)
    missing = setdiff(p.subjects, ga.subjects);
    if ~isempty(missing)
        error('cpsy1197:cluster:subjects', 'Participant(s) %s are not in the grand average of %s.', mat2str(missing), p.experiment);
    end
    sel = ismember(ga.subjects, p.subjects);
end
subjects = ga.subjects(sel); N = numel(subjects);
if N < 2
    error('cpsy1197:cluster:few', 'Only %d participant. A test across participants needs at least 2.', N);
end

%% ---------------------------------------------------------------- SETTINGS
lab = ga.individual.(c1).label; t = ga.individual.(c1).time;
if ~isempty(p.latency)
    lat = p.latency; what = 'chosen by you';
elseif strcmp(p.analysis, 'window')
    lat = ga.window; what = 'the window of the component, chosen in advance';
else
    lat = [0 0.8]; what = 'everything after the stimulus, exploratory';
end
lat = [max(lat(1), t(1)) min(lat(2), t(end))];
if lat(1) >= lat(2)
    error('cpsy1197:cluster:latency', 'The time window lies outside the data (%d to %d ms).', round(t(1)*1000), round(t(end)*1000));
end
nPossible = 2^N;
if isempty(p.numrandomization)
    if nPossible <= 5000, p.numrandomization = 'all'; else, p.numrandomization = 5000; end
end
if ischar(p.numrandomization), pmin = 2 / nPossible; else, pmin = 2 / (p.numrandomization + 1); end

% Only channels with a place on the layout can have neighbours.
[~, lay] = evalc('ft_prepare_layout(struct(''layout'', p.layout, ''feedback'', ''no''))');
inLay = ismember(lab, lay.label);
if sum(inLay) < 3
    error('cpsy1197:cluster:layout', 'Fewer than 3 channels of the data are on the layout %s.', p.layout);
end

% Neighbours: which channels may form a cluster together. Triangulation on
% the layout links each of the 30 channels to its 4 to 8 nearest
% neighbours. (FieldTrip's easycap template is made for 74 channels; with
% only 30 some channels, such as Fp1, would have no neighbour at all.)
cfg = []; cfg.method = 'triangulation'; cfg.layout = p.layout; cfg.channel = lab(inLay); cfg.feedback = 'no';
[~, neighbours] = evalc('ft_prepare_neighbours(cfg)');

% each condition as participants x channels x time
one = @(c) struct('individual', ga.individual.(c).individual(sel,:,:), 'label', {lab}, ...
                  'time', t, 'dimord', 'subj_chan_time');
A = one(c1); B = one(c2);

cfg                  = [];
cfg.channel          = lab(inLay);
cfg.latency          = lat;
cfg.parameter        = 'individual';
cfg.method           = 'montecarlo';          % p-value from random swaps
cfg.statistic        = 'ft_statfun_depsamplesT'; % paired t: each participant saw both conditions
cfg.correctm         = 'cluster';
cfg.clusteralpha     = p.clusteralpha;
cfg.clusterstatistic = 'maxsum';
cfg.minnbchan        = p.minnbchan;
cfg.neighbours       = neighbours;
cfg.tail             = 0;                      % two-sided: either condition can be larger
cfg.clustertail      = 0;
cfg.alpha            = p.alpha;
cfg.correcttail      = 'prob';                 % p-values doubled, so compare them with 0.05
cfg.numrandomization = p.numrandomization;
cfg.randomseed       = p.seed;
cfg.design           = [1:N 1:N; ones(1, N) 2 * ones(1, N)];
cfg.uvar             = 1;                      % row 1: which participant
cfg.ivar             = 2;                      % row 2: which condition

fprintf('\n=== CPSY 1197 cluster-based permutation test: %s ===\n', p.experiment);
fprintf('  %s minus %s, %d participants: %s\n', c1, c2, N, mat2str(subjects));
fprintf('  all %d channels, %d to %d ms (%s)\n', sum(inLay), round(lat(1)*1000), round(lat(2)*1000), what);
if any(~inLay), fprintf('  left out, no place on the layout: %s\n', strjoin(lab(~inLay), ' ')); end
if ischar(p.numrandomization)
    fprintf('  every possible swap of the two conditions (%d), so the p-value is exact\n', nPossible);
else
    fprintf('  %d random swaps of the two conditions (seed %d)\n', p.numrandomization, p.seed);
end
fprintf('  a point joins a cluster if its own p < %g and at least %d neighbouring channels pass too\n', p.clusteralpha, p.minnbchan);
tooFew = pmin >= p.alpha;
if tooFew
    fprintf(['  NOTE: with these %d swaps the smallest possible p is %.4f, so this test cannot get below %g.\n' ...
             '  It runs anyway, but to decide anything you need more participants (at least 6).\n'], ...
            iff(ischar(p.numrandomization), nPossible, p.numrandomization), pmin, p.alpha);
end

fprintf('  running, this can take a minute ...\n');
[~, stat] = evalc('ft_timelockstatistics(cfg, A, B)');   % evalc keeps FieldTrip''s own messages off the screen
% With every possible swap, FieldTrip counts only swaps whose largest
% cluster is strictly stronger than yours. That leaves out the swap that
% changes nothing (your own data), so the strongest cluster can get p = 0.
% Count "at least as strong" instead, as in step 4 above.
if ischar(p.numrandomization)
    sg = {'posclusters', 'posclusterslabelmat', 'posdistribution', 1; ...
          'negclusters', 'negclusterslabelmat', 'negdistribution', -1};
    stat.prob = ones(size(stat.stat));
    for d = 1:2
        if ~isfield(stat, sg{d, 1}), continue; end
        dist = sg{d, 4} * stat.(sg{d, 3});
        for q = 1:numel(stat.(sg{d, 1}))
            cs = sg{d, 4} * stat.(sg{d, 1})(q).clusterstat;
            pq = min(1, 2 * mean(dist >= cs - 1e-9 * abs(cs)));   % 2: two-sided, as correcttail = 'prob'
            stat.(sg{d, 1})(q).prob = pq;
            stat.prob(stat.(sg{d, 2}) == q) = pq;
        end
    end
    stat.mask = stat.prob <= p.alpha;
end

%% ---------------------------------------------------------------- THE RESULT
fprintf('\n');
best = 1; Cs = cell(1, 2);
dirs = {'pos', sprintf('%s more positive than %s', c1, c2); 'neg', sprintf('%s more negative than %s', c1, c2)};
for k = 1:2
    C = clusters(stat, dirs{k, 1}); Cs{k} = C;
    fprintf('  Clusters with %s:\n', dirs{k, 2});
    if isempty(C), fprintf('    none\n'); continue; end
    for q = 1:numel(C)
        if q > 1 && C(q).prob >= p.alpha, break; end
        fprintf('    %-12s  summed t %8.1f   %d to %d ms   %s\n', pstr(C(q).prob, pmin), C(q).clusterstat, ...
                round(C(q).t(1)*1000), round(C(q).t(2)*1000), chanlist(C(q).chans, numel(stat.label)));
    end
    best = min(best, C(1).prob);
end
fprintf('\n');
if best < p.alpha
    result = sprintf('Result: %s and %s differ (%s, below %g).', c1, c2, pstr(best, pmin), p.alpha);
elseif tooFew
    result = sprintf('Result: cannot be decided with %d participants (the smallest possible p is %.4f).', N, pmin);
elseif isempty(Cs{1}) && isempty(Cs{2})
    result = sprintf('Result: no difference between %s and %s was found (no point passed the threshold, so no cluster).', c1, c2);
else
    result = sprintf('Result: no difference between %s and %s was found (smallest %s).', c1, c2, pstr(best, pmin));
end
fprintf('  %s\n', result);
fprintf(['  Read it as: the conditions differ, or not. The times and channels of a cluster show where the\n' ...
         '  difference was strongest in these data. They are not the start, end or location of the effect.\n']);

%% ---------------------------------------------------------------- THE FIGURE
% One figure, four panels:
%   A  the ERPs at the component's channel, with the times this channel is in a cluster
%   B  where the p-value comes from: the largest cluster of every swap, and yours
%   C  t-values for every channel and time point, clusters with p < alpha outlined
%   D  scalp maps of the t-values, channels in such a cluster marked
sig  = sigmask(stat, p.alpha);                          % channels x time in a cluster with p < alpha
tms  = stat.time * 1000;
[~, il]  = ismember(stat.label, lay.label);
[~, ord] = sortrows([-lay.pos(il, 2) lay.pos(il, 1)]);  % front to back, then left to right
% colour scale for t: the 99th percentile of |t|, so that a few extreme values
% (with few participants t can get huge) do not wash out the rest
v    = sort(abs(stat.stat(isfinite(stat.stat)))); tl = 1;
if ~isempty(v) && v(ceil(0.99 * numel(v))) > 0, tl = v(ceil(0.99 * numel(v))); end
col  = struct('c1', [0.80 0.25 0.15], 'c2', [0.15 0.35 0.75], 'diff', [0.15 0.15 0.15], ...
              'clu', [0.95 0.60 0.20], 'win', [0.5 0.5 0.5]);

fig = figure('Name', ['Cluster test: ' p.experiment], 'Color', 'w', 'Position', [40 40 1250 900], ...
             'Visible', iff(p.show, 'on', 'off'));
colormap(fig, diverging());
lo = tiledlayout(fig, 3, 4, 'TileSpacing', 'compact', 'Padding', 'compact');
title(lo, {sprintf('%s: %s minus %s, %d participants, %d to %d ms', p.experiment, c1, c2, N, ...
           round(lat(1)*1000), round(lat(2)*1000)), result}, 'FontSize', 11);

% A. ERPs at the component's channel
axA = nexttile(lo, 1, [1 2]); hold(axA, 'on');
ci  = find(strcmp(lab, ga.channel)); cs = find(strcmp(stat.label, ga.channel));
if isempty(ci), ci = find(inLay, 1); end
w1  = squeeze(ga.individual.(c1).individual(sel, ci, :)); w2 = squeeze(ga.individual.(c2).individual(sel, ci, :));
wd  = squeeze(ga.individual.diff.individual(sel, ci, :));
mu  = mean(wd, 1); se = std(wd, 0, 1) / sqrt(N);
all3 = [mean(w1, 1); mean(w2, 1); mu + se; mu - se];
yl  = [min(all3(:)) max(all3(:))]; yl = yl + [-0.08 0.08] * max(diff(yl), eps);
fill(axA, lat([1 2 2 1]) * 1000, yl([1 1 2 2]), col.win, 'FaceAlpha', 0.10, 'EdgeColor', 'none', 'HandleVisibility', 'off');
if ~isempty(cs)
    e = diff([0 sig(cs, :) 0]); st = find(e == 1); en = find(e == -1) - 1;
    for k = 1:numel(st)
        fill(axA, tms([st(k) en(k) en(k) st(k)]), yl([1 1 2 2]), col.clu, 'FaceAlpha', 0.35, 'EdgeColor', 'none', 'HandleVisibility', 'off');
    end
end
fill(axA, [t fliplr(t)] * 1000, [mu + se fliplr(mu - se)], col.diff, 'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');
plot(axA, t * 1000, mean(w1, 1), 'Color', col.c1, 'LineWidth', 1.1, 'DisplayName', c1);
plot(axA, t * 1000, mean(w2, 1), 'Color', col.c2, 'LineWidth', 1.1, 'DisplayName', c2);
plot(axA, t * 1000, mu, 'Color', col.diff, 'LineWidth', 2, 'DisplayName', 'difference (band: SE)');
xline(axA, 0, 'Color', col.win, 'HandleVisibility', 'off'); yline(axA, 0, 'Color', col.win, 'HandleVisibility', 'off');
set(axA, 'Box', 'off', 'TickDir', 'out', 'XLim', 1000 * [t(1) t(end)], 'YLim', yl, 'FontSize', 8);
if p.negativeUp, set(axA, 'YDir', 'reverse'); end
legend(axA, 'Location', 'northwest', 'Box', 'off', 'FontSize', 7);
xlabel(axA, 'time (ms)'); ylabel(axA, 'uV');
title(axA, {sprintf('A   ERPs at %s', lab{ci}), ...
            sprintf('grey: tested time; orange: %s is in a cluster with p < %g', lab{ci}, p.alpha)}, ...
      'FontWeight', 'normal', 'FontSize', 9);

% B. Where the p-value comes from
axB = nexttile(lo, 3, [1 2]); hold(axB, 'on');
nulP = []; nulN = [];
if isfield(stat, 'posdistribution'), nulP = stat.posdistribution(1, :); end
if isfield(stat, 'negdistribution'), nulN = stat.negdistribution(1, :); end
nul  = [nulN(nulN ~= 0) nulP(nulP ~= 0)]; nNone = sum(nulP == 0 & nulN == 0);
obs  = [];
for k = 1:2, if ~isempty(Cs{k}), obs(end+1) = Cs{k}(1).clusterstat; end, end %#ok<AGROW>
xr   = [min([nul obs 0]) max([nul obs 0])]; xr = xr + [-0.05 0.05] * max(diff(xr), 1);
if ~isempty(nul)
    histogram(axB, nul, linspace(xr(1), xr(2), 60), 'FaceColor', [0.6 0.6 0.6], 'EdgeColor', 'none');
end
set(axB, 'XLim', xr, 'Box', 'off', 'TickDir', 'out', 'FontSize', 8);
yb = ylim(axB); if yb(2) <= 1, yb = [0 1]; ylim(axB, yb); end
for k = 1:2
    if isempty(Cs{k}), continue; end
    c = iff(k == 1, col.c1, col.c2);
    xline(axB, Cs{k}(1).clusterstat, 'Color', c, 'LineWidth', 2);
    text(axB, Cs{k}(1).clusterstat, yb(2) * 0.95, sprintf(' your data\n %s', pstr(Cs{k}(1).prob, pmin)), ...
         'Color', c, 'FontSize', 8, 'VerticalAlignment', 'top', ...
         'HorizontalAlignment', iff(Cs{k}(1).clusterstat > mean(xr), 'right', 'left'));
end
xlabel(axB, 'summed t of the largest cluster');
ylabel(axB, 'number of swaps');
title(axB, {'B   Where the p-value comes from', ...
            sprintf('grey: the largest cluster of each of %d swaps (%d without any cluster not shown)', ...
                    max(numel(nulP), numel(nulN)), nNone)}, 'FontWeight', 'normal', 'FontSize', 9);

% C. t-values for every channel and time point
axC = nexttile(lo, 5, [2 2]); hold(axC, 'on');
T = stat.stat(ord, :);
im = imagesc(axC, tms, 1:numel(ord), T); im.AlphaData = 0.35 + 0.65 * sig(ord, :);
dt = 1; if numel(tms) > 1, dt = tms(2) - tms(1); end
if any(sig(:)) && numel(tms) > 1
    % padded with a border of false, so every cluster gets a closed outline
    M = false(size(sig) + 2); M(2:end-1, 2:end-1) = sig(ord, :);
    contour(axC, [tms(1) - dt tms tms(end) + dt], 0:numel(ord) + 1, double(M), [0.5 0.5], 'k', 'LineWidth', 1);
end
axis(axC, 'tight'); set(axC, 'YDir', 'reverse'); clim(axC, [-tl tl]); colormap(axC, diverging());
xlim(axC, [tms(1) tms(end)] + [-0.5 0.5] * dt); ylim(axC, [0.5 numel(ord) + 0.5]);
set(axC, 'YTick', 1:numel(ord), 'YTickLabel', stat.label(ord), 'TickDir', 'out', 'Box', 'off', 'FontSize', 7);
xlabel(axC, 'time (ms)'); ylabel(axC, 'channel (front to back)');
title(axC, {'C   Paired t for every channel and time point', ...
            sprintf('red: %s more positive, blue: more negative; outlined: in a cluster with p < %g', c1, p.alpha)}, ...
      'FontWeight', 'normal', 'FontSize', 9);
cb = colorbar(axC); cb.Layout.Tile = 'east'; cb.Label.String = 't (C and D)';

% D. Scalp maps of the t-values in four steps across the tested time
S = struct('avg', stat.stat, 'label', {stat.label}, 'time', stat.time, 'dimord', 'chan_time');
edges = linspace(stat.time(1), stat.time(end), 5);
tiles = [7 8 11 12];
for k = 1:4
    ax = nexttile(lo, tiles(k));
    inWin = stat.time >= edges(k) & stat.time <= edges(k + 1);
    cfg = []; cfg.layout = p.layout; cfg.parameter = 'avg'; cfg.xlim = edges([k k + 1]); cfg.zlim = [-tl tl];
    cfg.figure = 'gca'; cfg.comment = 'no'; cfg.marker = 'on'; cfg.markersize = 2; cfg.markercolor = [0.3 0.3 0.3];
    cfg.colormap = diverging();
    cfg.highlight = 'on'; cfg.highlightchannel = stat.label(any(sig(:, inWin), 2));
    cfg.highlightsymbol = 'o'; cfg.highlightcolor = [0 0 0]; cfg.highlightsize = 5;
    evalc('ft_topoplotER(cfg, S)');
    % FieldTrip's marker colours are overruled by the axes colour order in
    % newer MATLAB versions, so set them here
    mk = findobj(ax, 'Type', 'line', '-not', 'Marker', 'none');
    set(mk(strcmp({mk.Marker}, 'o')), 'Color', 'k', 'MarkerEdgeColor', 'k', 'MarkerFaceColor', 'k');
    set(mk(~strcmp({mk.Marker}, 'o')), 'Color', [0.3 0.3 0.3], 'MarkerEdgeColor', [0.3 0.3 0.3]);
    clim(ax, [-tl tl]);
    rng_ms = sprintf('%d to %d ms', round(edges(k)*1000), round(edges(k + 1)*1000));
    if k == 1
        title(ax, {'D   Scalp maps of t, circles: in a cluster', rng_ms}, 'FontWeight', 'normal', 'FontSize', 9);
    else
        title(ax, {'', rng_ms}, 'FontWeight', 'normal', 'FontSize', 9);
    end
end

%% ------------------------------------------------------------------- SAVING
if p.save
    tag  = iff(isempty(p.latency), p.analysis, 'custom');
    base = fullfile(where, sprintf('clusterstat_%s_%s', p.experiment, tag));
    settings = rmfield(p, {'save', 'show'}); settings.latency = lat; settings.subjects = subjects; %#ok<NASGU>
    save([base '.mat'], 'stat', 'settings');
    if isgraphics(fig)
        drawnow;
        exportgraphics(fig, [base '.png'], 'Resolution', 150);
        fprintf('\nSaved %s.mat and %s.png\n', base, base);
    else
        fprintf('\nSaved %s.mat. The figure was closed before it could be saved; run again for the .png.\n', base);
    end
end
if ~p.show && isgraphics(fig), close(fig); end
fprintf('\n');
end

% ---------------------------------------------------------------------------
function C = clusters(stat, which)
% clusters of one sign, strongest first, with their time range and channels
C = struct('prob', {}, 'clusterstat', {}, 't', {}, 'chans', {});
fn = [which 'clusters']; if ~isfield(stat, fn) || isempty(stat.(fn)), return; end
lm = stat.([which 'clusterslabelmat']);
for k = 1:numel(stat.(fn))
    mk = lm == k; if ~any(mk(:)), continue; end
    tt = stat.time(any(mk, 1));
    [nch, ic] = sort(sum(mk, 2), 'descend'); ic = ic(nch > 0);
    C(end+1) = struct('prob', stat.(fn)(k).prob, 'clusterstat', stat.(fn)(k).clusterstat, ...
                      't', [tt(1) tt(end)], 'chans', {stat.label(ic)'}); %#ok<AGROW>
end
end

function M = sigmask(stat, alpha)
% channels x time: true where a point belongs to a cluster with p < alpha
M = false(size(stat.stat));
for w = {'pos', 'neg'}
    fn = [w{1} 'clusters'];
    if ~isfield(stat, fn) || isempty(stat.(fn)), continue; end
    good = find([stat.(fn).prob] < alpha);
    M = M | ismember(stat.([w{1} 'clusterslabelmat']), good);
end
end

function s = chanlist(ch, nAll)
% channel names, most involved first; shortened if there are many
if numel(ch) == nAll, s = sprintf('all %d channels', nAll);
elseif numel(ch) > 10, s = sprintf('%s and %d more', strjoin(ch(1:8), ' '), numel(ch) - 8);
else, s = strjoin(ch, ' ');
end
end

function s = pstr(pv, pmin)
% p-value as text; at the smallest value these swaps can give, p is that value or smaller
if pv <= pmin * (1 + 1e-9), s = sprintf('p <= %.4f', pmin); else, s = sprintf('p = %.4f', pv); end
end

function c = diverging()
% blue, white, red
n = 128; a = linspace(0, 1, n)';
c = [[a a ones(n, 1)]; [ones(n, 1) flipud(a) flipud(a)]];
end

function r = iff(c, a, b)
if c, r = a; else, r = b; end
end

function restoreft(before)
global ft_default %#ok<GVMIS>
ft_default = before;
ft_info on; ft_notice on;
end
