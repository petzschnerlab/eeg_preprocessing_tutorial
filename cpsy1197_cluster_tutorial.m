function cpsy1197_cluster_tutorial(where, params)
% CPSY1197_CLUSTER_TUTORIAL  A guided tour through the cluster-based permutation test.
%
%   cpsy1197_cluster_tutorial('data')
%   cpsy1197_cluster_tutorial('data', struct('experiment', 'N170'))
%
% cpsy1197_cluster_test gives you the result in one go. This script does the
% same test step by step, on your own grand average, and stops after every
% step: it shows a figure, explains it, sometimes asks you a question, and
% waits until you press Enter. Three times it asks you to type an answer.
% Nothing is graded; the questions are there to make you think first and
% look second.
%
% The steps
%   1. Your data: the two conditions and their difference
%   2. One t-test for every channel and time point, and why that is a problem
%   3. Clusters: neighbouring points that pass the threshold
%   4. Swapping the conditions: what chance alone looks like
%   5. Many swaps: where the p-value comes from
%   6. What you can write in your report
%   7. What depends on your choices: the threshold and the number of participants
%   8. The same test in FieldTrip (cpsy1197_cluster_test)
%
% Steps 2 to 5 are computed in this file in plain MATLAB, so you can read
% how it is done. Step 8 runs FieldTrip and compares the two results.
% It takes about 15 minutes. Press Ctrl+C to stop at any time.
%
% params (all optional)
%   experiment   'P3b', 'N170' or 'N400'. If the folder holds more than one and you give none, you are asked.
%   analysis     'window' (default) or 'full', as in cpsy1197_cluster_test.
%   subjects     participant numbers to use. Default: all in the grand average.
%   seed         start of the random numbers. Default 42.
%   fieldtrip    false: skip step 8. Default true.
%   wait         false: do not stop between the steps and ask nothing. Default true (false with -batch).
%   figures      a folder: save the figure of every step there as a .png. Default: none.
%
% See also CPSY1197_CLUSTER_TEST, CPSY1197_AVERAGE_ACROSS

if nargin < 1, where  = 'data'; end
if nargin < 2, params = struct(); end
if isempty(which('ft_defaults'))
    error(['FieldTrip is not on your MATLAB path. Run addpath with your ' ...
           'FieldTrip folder, then cpsy1197_check.']);
end
global ft_default %#ok<GVMIS> FieldTrip keeps its defaults in this global
ftBefore  = ft_default;
ftRestore = onCleanup(@() restoreft(ftBefore)); %#ok<NASGU>
ft_default.showcallinfo = 'no';
ft_default.trackusage   = false;
ft_defaults;
ft_info off; ft_notice off;

p.experiment = ft_getopt(params, 'experiment', '');
p.analysis   = ft_getopt(params, 'analysis',   'window');
p.subjects   = ft_getopt(params, 'subjects',   []);
p.seed       = ft_getopt(params, 'seed',       42);
p.fieldtrip  = ft_getopt(params, 'fieldtrip',  true);
p.wait       = ft_getopt(params, 'wait',       ~batchStartupOptionUsed);
p.figures    = ft_getopt(params, 'figures',    '');
p.layout     = fullfile(fileparts(which('ft_defaults')), 'template', 'layout', 'easycapM1.mat');
if ~ismember(p.analysis, {'window', 'full'})
    error('cpsy1197:tutorial:analysis', 'analysis must be ''window'' or ''full'', not "%s".', p.analysis);
end
if ~isempty(p.figures) && ~isfolder(p.figures), mkdir(p.figures); end
rngBefore  = rng;
rngRestore = onCleanup(@() rng(rngBefore)); %#ok<NASGU>
rng(p.seed, 'twister');

%% ---------------------------------------------------------- THE GRAND AVERAGE
if ~isfolder(where)
    error('cpsy1197:tutorial:nofolder', 'Cannot find the folder "%s".', where);
end
d = dir(fullfile(where, 'grandavg_*.mat')); d = d(~startsWith({d.name}, '._'));
if isempty(d)
    error('cpsy1197:tutorial:nofile', 'No grandavg_*.mat in "%s". Run cpsy1197_average_across first.', where);
end
expts = regexprep({d.name}, '^grandavg_(.*)\.mat$', '$1');
if isempty(p.experiment)
    if numel(expts) == 1 || ~p.wait
        p.experiment = expts{1};
    else
        fprintf('\nThe folder holds grand averages of more than one experiment.\n');
        for k = 1:numel(expts), fprintf('  %d  %s\n', k, expts{k}); end
        choice = [];
        while ~(isscalar(choice) && ismember(choice, 1:numel(expts)))
            choice = input(sprintf('Which one? Type 1 to %d, or 0 to stop: ', numel(expts)));
            if isequal(choice, 0), fprintf('Stopped.\n'); return; end
        end
        p.experiment = expts{choice};
    end
end
f = fullfile(where, ['grandavg_' p.experiment '.mat']);
if ~isfile(f)
    error('cpsy1197:tutorial:noexperiment', 'There is no %s. Run cpsy1197_average_across for %s first.', f, p.experiment);
end
s = load(f, 'ga'); ga = s.ga; c1 = ga.measure.first; c2 = ga.measure.second;

sel = true(size(ga.subjects));
if ~isempty(p.subjects)
    missing = setdiff(p.subjects, ga.subjects);
    if ~isempty(missing)
        error('cpsy1197:tutorial:subjects', 'Participant(s) %s are not in the grand average of %s.', mat2str(missing), p.experiment);
    end
    sel = ismember(ga.subjects, p.subjects);
end
subjects = ga.subjects(sel); N = numel(subjects);
if N < 2
    error('cpsy1197:tutorial:few', 'Only %d participant. A test across participants needs at least 2.', N);
end

%% ------------------------------------------------------------- THE SETTINGS
% the same as in cpsy1197_cluster_test
clusteralpha = 0.05; alpha = 0.05; minnb = 2;
lab = ga.individual.(c1).label; t = ga.individual.(c1).time;
if strcmp(p.analysis, 'window'), lat = ga.window; else, lat = [0 0.8]; end
[~, i1] = min(abs(t - lat(1))); [~, i2] = min(abs(t - lat(2)));   % nearest samples, as FieldTrip does
tw = i1:i2;

[~, lay] = evalc('ft_prepare_layout(struct(''layout'', p.layout, ''feedback'', ''no''))');
inLay = ismember(lab, lay.label);
labT  = lab(inLay); nC = numel(labT); nT = numel(tw); P = nC * nT;
cfg = []; cfg.method = 'triangulation'; cfg.layout = p.layout; cfg.channel = labT; cfg.feedback = 'no';
[~, neighbours] = evalc('ft_prepare_neighbours(cfg)');

% Nb(i,j) = 1 if channels i and j are neighbours
Nb = zeros(nC);
for k = 1:numel(neighbours)
    i = strcmp(labT, neighbours(k).label);
    Nb(i, ismember(labT, neighbours(k).neighblabel)) = 1;
end
Nb = double(Nb | Nb');
% Adj: which of the P points (channel x time) touch: the same channel at the
% next sample, or a neighbouring channel at the same sample
idx = reshape(1:P, nC, nT);
a = idx(:, 1:end-1); b = idx(:, 2:end);
[ci, cj] = find(triu(Nb));
ea = idx(ci, :); eb = idx(cj, :);
Adj = sparse([a(:); ea(:)], [b(:); eb(:)], 1, P, P); Adj = Adj | Adj';

% each participant's difference c1 - c2, participants x (channel x time)
X1 = ga.individual.(c1).individual(sel, inLay, tw);
X2 = ga.individual.(c2).individual(sel, inLay, tw);
Dm = reshape(X1 - X2, N, P);
df = N - 1;
tcrit = tcritical(clusteralpha, df);

tms = t(tw) * 1000;
[~, il]  = ismember(labT, lay.label);
[~, ord] = sortrows([-lay.pos(il, 2) lay.pos(il, 1)]);       % front to back
ch = find(strcmp(labT, ga.channel)); if isempty(ch), ch = 1; end
chAll = find(strcmp(lab, labT{ch}));
col = struct('c1', [0.80 0.25 0.15], 'c2', [0.15 0.35 0.75], 'diff', [0.15 0.15 0.15], ...
             'flip', [0.95 0.55 0.15], 'win', [0.5 0.5 0.5]);
fig = [];

T0 = pairedt(ones(1, N), Dm, N);                               % your data
T0m = reshape(T0, nC, nT);
v = sort(abs(T0(isfinite(T0)))); tl = 1;
if ~isempty(v) && v(ceil(0.99 * numel(v))) > 0, tl = v(ceil(0.99 * numel(v))); end

fprintf('\n');
para(sprintf(['CPSY 1197: a guided tour through the cluster-based permutation test. Experiment %s, ' ...
              '%s minus %s, %d participants. Read the text, look at the figure, then press Enter.'], ...
              p.experiment, c1, c2, N));

%% ------------------------------------------------------------- 1. YOUR DATA
header(1, 'Your data');
[fig, lo] = stationfig(fig, p, 1, 1);
ax = nexttile(lo); hold(ax, 'on');
w1 = squeeze(ga.individual.(c1).individual(sel, chAll, :)); w2 = squeeze(ga.individual.(c2).individual(sel, chAll, :));
wd = w1 - w2;
mu = mean(wd, 1); se = std(wd, 0, 1) / sqrt(N);
yl = range3([mean(w1, 1); mean(w2, 1); mu + se; mu - se]);
fill(ax, t([tw(1) tw(end) tw(end) tw(1)]) * 1000, yl([1 1 2 2]), col.win, 'FaceAlpha', 0.12, 'EdgeColor', 'none', 'HandleVisibility', 'off');
fill(ax, [t fliplr(t)] * 1000, [mu + se fliplr(mu - se)], col.diff, 'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');
plot(ax, t * 1000, mean(w1, 1), 'Color', col.c1, 'LineWidth', 1.2, 'DisplayName', c1);
plot(ax, t * 1000, mean(w2, 1), 'Color', col.c2, 'LineWidth', 1.2, 'DisplayName', c2);
plot(ax, t * 1000, mu, 'Color', col.diff, 'LineWidth', 2, 'DisplayName', 'difference (band: standard error)');
xline(ax, 0, 'Color', col.win, 'HandleVisibility', 'off'); yline(ax, 0, 'Color', col.win, 'HandleVisibility', 'off');
nice(ax, 'time (ms)', 'uV'); xlim(ax, 1000 * [t(1) t(end)]); ylim(ax, yl);
legend(ax, 'Location', 'northwest', 'Box', 'off');
title(ax, {sprintf('%s: the average ERPs at %s, %d participants', p.experiment, labT{ch}, N), ...
           sprintf('grey: the time the test looks at, %d to %d ms', round(tms(1)), round(tms(end)))}, 'FontWeight', 'normal');
savestep(fig, p, 1);
para(sprintf(['The figure shows the average ERP of %s (red) and %s (blue) at %s, the channel where ERP CORE ' ...
              'measures the %s, and their difference (black, with its standard error). The test will look at ' ...
              'all %d channels from %d to %d ms (grey).'], c1, c2, labT{ch}, p.experiment, nC, round(tms(1)), round(tms(end))));
para(sprintf(['Think: do %s and %s differ? If so, when, and would you expect it only at %s or also on other ' ...
              'channels? Keep your guess in mind.'], c1, c2, labT{ch}));
goon(p);

%% ---------------------------------------------------- 2. ONE TEST PER POINT
header(2, 'One t-test for every channel and time point');
pt = tp(T0, df); nSig = sum(pt < 0.05);
para(sprintf(['For every channel and time point a paired t-test compares %s and %s across your %d participants ' ...
              '(paired: everyone saw both, so the test uses each participant''s own difference). That is %d ' ...
              'channels x %d time points = %d tests. %d of them have p < 0.05.'], c1, c2, N, nC, nT, P, nSig));
[fig, lo] = stationfig(fig, p, 1, 1);
ax = nexttile(lo);
tmapplot(ax, T0m, reshape(pt < 0.05, nC, nT), [], tms, labT, ord, tl);
title(ax, {sprintf('Your data: paired t for each of the %d points', P), ...
           sprintf('outlined: p < 0.05 (%d points). Red: %s more positive, blue: more negative', nSig, c1)}, 'FontWeight', 'normal');
savestep(fig, p, 2);
guess = asknumber(p, sprintf(['QUESTION. Suppose %s and %s did not differ at all. How many of the %d points ' ...
                              'would you still expect to have p < 0.05, just by chance? Type a number: '], c1, c2, P));
expct = round(0.05 * P);
if ~isempty(guess), fprintf('  You said %g. ', guess); else, fprintf('  '); end
fprintf('About 5%% of them, so about %d. Each test has a 5%% chance of a false alarm.\n\n', expct);
goon(p);

% the same after swapping the conditions for half of the participants
flip = sort(randperm(N, max(1, floor(N / 2))));
sg = ones(1, N); sg(flip) = -1;
T1 = pairedt(sg, Dm, N); p1 = tp(T1, df);
% and how many points pass by chance over many random swaps
nR = 200; cnt2 = zeros(1, nR);
for r = 1:nR
    cnt2(r) = sum(tp(pairedt(1 - 2 * (rand(1, N) > 0.5), Dm, N), df) < 0.05);
end
[fig, lo] = stationfig(fig, p, 1, 3);
ax = nexttile(lo); tmapplot(ax, T0m, reshape(pt < 0.05, nC, nT), [], tms, labT, ord, tl);
title(ax, {'Your data', sprintf('%d points with p < 0.05', nSig)}, 'FontWeight', 'normal');
ax = nexttile(lo); tmapplot(ax, reshape(T1, nC, nT), reshape(p1 < 0.05, nC, nT), [], tms, labT, ord, tl);
title(ax, {sprintf('Conditions swapped for %s', mat2str(subjects(flip))), ...
           sprintf('%d points with p < 0.05, although any real difference is gone', sum(p1 < 0.05))}, 'FontWeight', 'normal');
ax = nexttile(lo); hold(ax, 'on');
histogram(ax, cnt2, 30, 'FaceColor', [0.6 0.6 0.6], 'EdgeColor', 'none');
xline(ax, expct, 'k--', 'LineWidth', 1.5);
nice(ax, 'points with p < 0.05', 'number of swaps');
title(ax, {sprintf('%d random swaps', nR), sprintf('dashed: 5%% of %d = %d', P, expct)}, 'FontWeight', 'normal');
savestep(fig, p, 2.5);
para(sprintf(['Middle: the same, but for participants %s the labels %s and %s were swapped. That cancels any real ' ...
              'difference, so whatever is left is chance: %d points with p < 0.05. Right: the same for %d random ' ...
              'swaps. On average %.0f points pass, close to 5%%, but it ranges from %d to %d: neighbouring channels ' ...
              'and time points carry similar signals, so false alarms come in clumps. Sometimes none, sometimes ' ...
              'hundreds. So you cannot count significant points, or pick the most striking one. The cluster test ' ...
              'turns all %d tests into one.'], mat2str(subjects(flip)), c1, c2, sum(p1 < 0.05), nR, mean(cnt2), ...
              min(cnt2), max(cnt2), P));
goon(p);

%% --------------------------------------------------------------- 3. CLUSTERS
header(3, 'Clusters');
[cl0, L0] = findclusters(T0m, tcrit, Nb, Adj, minnb);
para(sprintf(['Step 1: keep the points with p < %g, here |t| > %.2f (with %d participants). Step 2: a kept point ' ...
              'stays only if at least %d of its neighbouring channels are kept at the same time, which removes ' ...
              'isolated spikes. Step 3: kept points that touch, in time or on neighbouring channels, form a ' ...
              'cluster; positive and negative t form separate clusters. Step 4: a cluster''s strength is the sum ' ...
              'of its t-values, so it grows with both how strong and how large the difference is.'], ...
              clusteralpha, tcrit, N, minnb));
[fig, lo] = stationfig(fig, p, 1, 3);
ax = nexttile(lo, 1); neighbourplot(ax, lay, labT, Nb, ch);
title(ax, {'Which channels are neighbours', sprintf('each line links two neighbours; %s in black', labT{ch})}, 'FontWeight', 'normal');
ax = nexttile(lo, 2, [1 2]);
strong = []; if ~isempty(cl0.id), strong = L0 == cl0.id(1); end
tmapplot(ax, T0m, L0 > 0, strong, tms, labT, ord, tl);
for k = 1:min(5, numel(cl0.sum))
    [r, c] = find(L0(ord, :) == cl0.id(k));
    text(ax, mean(tms(c)), mean(r), sprintf('%d', k), 'FontWeight', 'bold', 'FontSize', 11, 'HorizontalAlignment', 'center');
end
title(ax, {sprintf('Your clusters (%d), numbered by strength', numel(cl0.sum)), ...
           'thick outline: the strongest; faded: not in a cluster'}, 'FontWeight', 'normal');
savestep(fig, p, 3);
if isempty(cl0.sum)
    obs = 0; obsSign = 1;
    para(['No point passed all steps, so there is no cluster. The strongest cluster has summed t = 0, and the ' ...
          'test cannot find a difference. Go on anyway to see how the test works.']);
else
    fprintf('  Your clusters, strongest first:\n');
    for k = 1:min(5, numel(cl0.sum))
        m = L0 == cl0.id(k);
        fprintf('    %d   summed t %9.1f   %4d to %4d ms   %2d channels\n', k, cl0.sum(k), ...
                round(min(tms(any(m, 1)))), round(max(tms(any(m, 1)))), sum(any(m, 2)));
    end
    if numel(cl0.sum) > 5, fprintf('    and %d smaller ones\n', numel(cl0.sum) - 5); end
    fprintf('\n');
    obs = cl0.sum(1); obsSign = sign(obs);
    para(sprintf(['Your strongest cluster has summed t = %.1f. The question for the next steps: could a cluster ' ...
                  'this strong come about by chance, if %s and %s did not differ?'], obs, c1, c2));
end
goon(p);

%% ------------------------------------------------------------ 4. SWAPPING
header(4, 'What chance looks like: swapping the conditions');
para(sprintf(['If %s and %s did not differ, it would not matter which of a participant''s two ERPs is called ' ...
              '"%s". Swapping the two turns that participant''s difference wave upside down. So: pick ' ...
              'participants at random, flip their difference waves, and repeat steps 2 and 3. Whatever cluster ' ...
              'comes out is what chance alone can produce.'], c1, c2, c1));
para('Think: after a swap, will the strongest cluster be stronger or weaker than yours?');
goon(p);
wch = wd;
for r = 1:3
    sg = 1 - 2 * (rand(1, N) > 0.5);
    if all(sg == 1), sg(randi(N)) = -1; end
    Tr = reshape(pairedt(sg, Dm, N), nC, nT);
    [clr, Lr] = findclusters(Tr, tcrit, Nb, Adj, minnb);
    best = 0; if ~isempty(clr.sum), best = clr.sum(1); end
    if best == 0, bestTxt = 'no cluster (summed t = 0)'; else, bestTxt = sprintf('summed t = %.1f', best); end
    [fig, lo] = stationfig(fig, p, 1, 2);
    ax = nexttile(lo); hold(ax, 'on');
    for q = 1:N
        if sg(q) < 0
            plot(ax, t * 1000, -wch(q, :), 'Color', [col.flip 0.6], 'LineWidth', 0.7);
        else
            plot(ax, t * 1000, wch(q, :), 'Color', [0.6 0.6 0.6 0.5], 'LineWidth', 0.7);
        end
    end
    plot(ax, t * 1000, mu, '--', 'Color', col.diff, 'LineWidth', 1.2);
    plot(ax, t * 1000, mean(sg(:) .* wch, 1), 'Color', col.diff, 'LineWidth', 2.2);
    xline(ax, 0, 'Color', col.win); yline(ax, 0, 'Color', col.win);
    nice(ax, 'time (ms)', 'uV'); xlim(ax, 1000 * [t(1) t(end)]);
    title(ax, {sprintf('Swap %d: each participant''s difference at %s', r, labT{ch}), ...
               sprintf('orange: flipped (%d of %d); black: new average; dashed: yours', sum(sg < 0), N)}, 'FontWeight', 'normal');
    ax = nexttile(lo);
    strong = []; if ~isempty(clr.id), strong = Lr == clr.id(1); end
    tmapplot(ax, Tr, Lr > 0, strong, tms, labT, ord, tl);
    title(ax, {sprintf('Swap %d: t and clusters', r), ...
               sprintf('strongest cluster: %s (yours: %.1f)', bestTxt, obs)}, 'FontWeight', 'normal');
    savestep(fig, p, 4 + r / 10);
    fprintf('  Swap %d: flipped %d of %d participants. Strongest cluster: %s (yours: %.1f).\n', ...
            r, sum(sg < 0), N, bestTxt, obs);
    goon(p);
end
para(['Flipping a random set of participants mixes the two directions, so the average difference shrinks and ' ...
      'the clusters are usually weaker than yours if there is a real effect. If there is none, a swap is just ' ...
      'as likely as your data to give a strong cluster.']);

%% ------------------------------------------------------- 5. MANY SWAPS
header(5, 'Many swaps: where the p-value comes from');
nPossible = 2^N;
if nPossible <= 5000
    S = 1 - 2 * double(dec2bin(0:nPossible - 1, N) == '1');   % every pattern; the first row swaps nobody
    para(sprintf(['With %d participants there are 2^%d = %d ways to swap (each participant swapped or not). The ' ...
                  'script tries every one of them and notes the strongest positive and the strongest negative ' ...
                  'cluster of each.'], N, N, nPossible));
else
    S = [ones(1, N); 1 - 2 * (rand(1000, N) > 0.5)];
    para(sprintf(['With %d participants there are 2^%d ways to swap, far too many. The script takes 1000 at random ' ...
                  '(cpsy1197_cluster_test takes 5000), plus your own data, and notes the strongest positive and ' ...
                  'the strongest negative cluster of each.'], N, N));
end
nS = size(S, 1); pmin = 2 / nS;
[fig, lo] = stationfig(fig, p, 1, 1); axH = nexttile(lo);
fprintf('  running %d swaps ...\n', nS);
[nulP, nulN] = nulldist(S, Dm, N, nC, nT, tcrit, Nb, Adj, minnb, @(np, nn, done) livehist(axH, np, nn, done, nS, p));
xr = livehist(axH, nulP, nulN, nS, nS, p);
savestep(fig, p, 5);
fprintf('\n');
if obs ~= 0
    g = asknumber(p, sprintf(['QUESTION. Your strongest cluster has summed t = %.1f. In the histogram, what share ' ...
                              'of the swaps has a cluster at least this strong (same sign)? Type a number between 0 and 1: '], obs));
else
    g = [];
end
if obsSign > 0, dist = nulP; else, dist = -nulN; end
cnt = sum(dist >= abs(obs) - 1e-9 * abs(obs)); share = cnt / nS;
pval = min(1, 2 * share); if obs == 0, pval = 1; end
hold(axH, 'on');
if obs ~= 0
    xline(axH, obs, 'Color', iff(obs > 0, col.c1, col.c2), 'LineWidth', 2.5);
    yb = ylim(axH);
    text(axH, obs, yb(2) * 0.95, sprintf(' your data\n p = %.4f', pval), 'Color', iff(obs > 0, col.c1, col.c2), ...
         'VerticalAlignment', 'top', 'HorizontalAlignment', iff(obs > mean(xr), 'right', 'left'));
end
savestep(fig, p, 5.5);
if ~isempty(g), fprintf('  You said %g. ', g); else, fprintf('  '); end
if obs ~= 0
    fprintf('The answer: %d of %d swaps, a share of %.4f.\n\n', cnt, nS, share);
    para(sprintf(['You would have been just as interested in a cluster of the other sign, so the share is doubled: ' ...
                  'p = 2 x %.4f = %.4f. One of the swaps is "swap nobody": that is your own data, the grey bar ' ...
                  'right under your line. (Its mirror image on the other side is "swap everybody".) So at least ' ...
                  'one swap always reaches your cluster, and p can never be below 2/%d = %.4f.'], share, pval, nS, pmin));
else
    fprintf('Without a cluster there is nothing to compare: p = 1.\n\n');
end
tooFew = pmin >= alpha;
if tooFew
    para(sprintf(['NOTE: with %d participants the smallest possible p is %.4f, which is not below %g. Whatever ' ...
                  'your data look like, this test cannot decide. You need at least 6 participants.'], N, pmin, alpha));
end
goon(p);

%% --------------------------------------------------------- 6. YOUR REPORT
header(6, 'What you can write in your report');
if tooFew
    opts = {sprintf('%s and %s differed (p = %.4f).', c1, c2, pval), ...
            sprintf('%s and %s did not differ (p = %.4f).', c1, c2, pval), ...
            sprintf('With %d participants the test could not decide whether %s and %s differ.', N, c1, c2)};
    right = 3;
    fb = {'No: p is not below 0.05, and with so few participants it cannot be.', ...
          'No: the test never shows that conditions do not differ, and here it could not have found a difference at all.', ...
          sprintf('Yes. With %d participants the smallest possible p is %.4f.', N, pmin)};
elseif pval < alpha
    m = L0 == cl0.id(1); tt = tms(any(m, 1));
    [~, io] = sort(sum(m, 2), 'descend'); cc = labT(io);   % most involved channels first
    opts = {sprintf('%s and %s differed (cluster-based permutation test, p = %.4f).', c1, c2, pval), ...
            sprintf('The difference between %s and %s started at %d ms.', c1, c2, round(tt(1))), ...
            sprintf('The difference was located at %s.', strjoin(cc(1:min(3, end)), ', ')), ...
            sprintf('%s and %s differed significantly from %d to %d ms.', c1, c2, round(tt(1)), round(tt(end)))};
    right = 1;
    fb = {['Yes. The test answers one question: do the conditions differ? You may add where the difference was ' ...
           'strongest in these data, as a description.'], ...
          sprintf(['No. %d ms is the first sample of the cluster, and that depends on the threshold, the noise ' ...
                   'and the time window (the window starts at %d ms). The test says nothing about onsets.'], ...
                   round(tt(1)), round(tms(1))), ...
          'No. The channels in a cluster are where the difference passed the threshold, not where the effect is.', ...
          ['No. This is the most common mistake: the p-value belongs to the whole test, not to each point of ' ...
           'the cluster, so no single time point is "significant".']};
else
    opts = {sprintf('%s and %s do not differ (p = %.4f).', c1, c2, pval), ...
            sprintf('No difference between %s and %s was found (cluster-based permutation test, p = %.4f).', c1, c2, pval), ...
            'There was a difference, but it was too small.'};
    right = 2;
    fb = {'No. Not finding a difference does not show there is none: the effect may be small, or you may have too few participants.', ...
          'Yes. The test did not find a difference. That is all it says.', ...
          'No. The test gives no evidence for any difference, small or large.'};
end
fprintf('  QUESTION. Which sentence belongs in your report?\n');
for k = 1:numel(opts), fprintf('    %c) %s\n', 'a' + k - 1, opts{k}); end
fprintf('\n');
ans6 = askletter(p, '  Type a letter: ', numel(opts));
for k = 1:numel(opts)
    mark = iff(k == right, 'right', 'wrong');
    if ~isempty(ans6) && k == ans6, mark = [mark ', your choice']; end %#ok<AGROW>
    fprintf('  %c) %s: ', 'a' + k - 1, mark); para2(fb{k});
end
para(['See also the FieldTrip FAQ "How NOT to interpret results from a cluster-based permutation test" ' ...
      '(link in TUTORIAL_Averaging.md).']);
goon(p);

%% ------------------------------------------------- 7. WHAT DEPENDS ON CHOICES
header(7, 'What depends on your choices');
para(sprintf(['The threshold of step 3 (p < %g for a point to join a cluster) is a choice. Here is the whole test ' ...
              'again with a stricter (0.01) and a looser (0.10) threshold.'], clusteralpha));
cas = [0.01 clusteralpha 0.10];
[fig, lo] = stationfig(fig, p, 1, 3);
fprintf('  running ...\n');
for k = 1:3
    tc = tcritical(cas(k), df);
    [clk, Lk] = findclusters(T0m, tc, Nb, Adj, minnb);
    if cas(k) == clusteralpha
        np = nulP; nn = nulN;
    else
        [np, nn] = nulldist(S, Dm, N, nC, nT, tc, Nb, Adj, minnb, []);
    end
    pk = 1; desc = 'no cluster'; strong = [];
    if ~isempty(clk.sum)
        o = clk.sum(1);
        if o > 0, dk = np; else, dk = -nn; end
        pk = min(1, 2 * mean(dk >= abs(o) - 1e-9 * abs(o)));
        strong = Lk == clk.id(1); tt = tms(any(strong, 1));
        desc = sprintf('%d to %d ms, %d channels', round(tt(1)), round(tt(end)), sum(any(strong, 2)));
    end
    ax = nexttile(lo);
    tmapplot(ax, T0m, Lk > 0, strong, tms, labT, ord, tl);
    title(ax, {sprintf('threshold p < %g (|t| > %.2f)', cas(k), tc), sprintf('strongest: %s', desc), ...
               sprintf('p = %.4f', pk)}, 'FontWeight', 'normal');
    fprintf('    threshold %.2f:  strongest cluster %-32s p = %.4f\n', cas(k), desc, pk);
end
savestep(fig, p, 7);
fprintf('\n');
para(['The edges of the clusters move with the threshold; the answer to the question (differ or not) usually ' ...
      'does not. That is why the edges are not "the time of the effect". Choose the threshold before you look ' ...
      'at the data: trying several and reporting the one that works makes the p-value meaningless.']);
fprintf('  And the number of participants: the smallest possible p is 2 divided by the number of swaps.\n');
fprintf('    participants   swaps   smallest p\n');
for n = unique([3:8 10 N])
    fprintf('    %8d   %9d   %8.4f%s\n', n, 2^n, 2 / 2^n, iff(n == N, '   <- you', ''));
end
fprintf('\n');
para('Below 6 participants no result can reach p < 0.05. With more participants the test also gets more sensitive.');
goon(p);

%% ----------------------------------------------------------- 8. FIELDTRIP
header(8, 'The same test in FieldTrip');
if p.fieldtrip
    para(['cpsy1197_cluster_test runs the same test with FieldTrip''s ft_timelockstatistics. It also saves the ' ...
          'result and its figure in your data folder. Running it now ...']);
    st = cpsy1197_cluster_test(where, struct('experiment', p.experiment, 'analysis', p.analysis, ...
                                             'subjects', subjects, 'seed', p.seed, 'show', p.wait));
    ftp = 1;
    for w = {'posclusters', 'negclusters'}
        if isfield(st, w{1}) && ~isempty(st.(w{1})), ftp = min(ftp, min([st.(w{1}).prob])); end
    end
    fprintf('  This tour: p = %.4f.   FieldTrip: p = %.4f.\n', pval, ftp);
    if nPossible <= 5000
        para('Both tried every possible swap, so the two must agree.');
    else
        if abs(pval - pmin) < 1e-12
            para(sprintf(['Both drew random swaps (1000 here, 5000 in FieldTrip). None of them reached your cluster, ' ...
                          'so each p is simply its smallest possible value: 2/%d here, about 2/5000 in FieldTrip. Both ' ...
                          'say the same thing: p is below %g.'], nS, alpha));
        else
            para('Both drew random swaps (1000 here, 5000 in FieldTrip), so the two agree closely but not exactly.');
        end
    end
else
    para('Skipped. Run cpsy1197_cluster_test(''data'') for the result you report.');
end
para(['That is the whole test. Compare it with your guess from step 1. For your report use ' ...
      'cpsy1197_cluster_test and see TUTORIAL_Averaging.md, section 3.']);
if ~p.wait && isgraphics(fig), close(fig); end
end

% =============================================================================
function T = pairedt(sg, Dm, N)
% paired t for each column of Dm, after multiplying participant i by sg(i)
% (sg = -1 means: the conditions of this participant are swapped)
m  = (sg * Dm) / N;
v  = (sum(Dm.^2, 1) - N * m.^2) / (N - 1);                   % flipping signs does not change sum(Dm.^2)
T  = m ./ sqrt(v / N);
end

function pv = tp(T, df)
% two-sided p of a t-value, without the Statistics Toolbox
pv = betainc(df ./ (df + T.^2), df / 2, 0.5);
end

function tc = tcritical(a, df)
% |t| above which the two-sided p is below a
tc = fzero(@(x) tp(x, df) - a, [0 1e4]);
end

function [cl, L] = findclusters(T, tc, Nb, Adj, minnb)
% clusters of t-values beyond +-tc; strongest (largest |summed t|) first
L = zeros(size(T)); sums = []; n = 0;
for sgn = [1 -1]
    on = sgn * T > tc;
    while minnb > 0                                           % drop points with too few kept neighbours
        drop = on & (Nb * double(on)) < minnb;
        if ~any(drop(:)), break; end
        on(drop) = false;
    end
    k = find(on);
    if isempty(k), continue; end
    bins = conncomp(graph(Adj(k, k)));                        % groups of touching points
    L(k) = bins + n;
    sums = [sums accumarray(bins(:), T(k))']; %#ok<AGROW>
    n = n + max(bins);
end
[~, o] = sort(abs(sums), 'descend');
cl = struct('sum', sums(o), 'id', o);
end

function [nulP, nulN] = nulldist(S, Dm, N, nC, nT, tc, Nb, Adj, minnb, live)
% the strongest positive and negative cluster for every row of S
nS = size(S, 1); nulP = zeros(1, nS); nulN = zeros(1, nS);
chunk = max(1, ceil(nS / 20));
for a = 1:chunk:nS
    rows = a:min(nS, a + chunk - 1);
    Tc = pairedt(S(rows, :), Dm, N);
    for r = 1:numel(rows)
        cl = findclusters(reshape(Tc(r, :), nC, nT), tc, Nb, Adj, minnb);
        if any(cl.sum > 0), nulP(rows(r)) = max(cl.sum); end
        if any(cl.sum < 0), nulN(rows(r)) = min(cl.sum); end
    end
    if ~isempty(live), live(nulP, nulN, rows(end)); end
end
end

function xr = livehist(ax, nulP, nulN, done, nS, p)
% histogram of the strongest clusters of the swaps so far
if ~isgraphics(ax), xr = [-1 1]; return; end
v = [nulN(1:done) nulP(1:done)]; v = v(v ~= 0);
xr = [min([v 0]) max([v 0])]; xr = xr + [-0.05 0.05] * max(diff(xr), 1);
cla(ax); hold(ax, 'on'); ylim(ax, 'auto');
if ~isempty(v), histogram(ax, v, linspace(xr(1), xr(2), 60), 'FaceColor', [0.6 0.6 0.6], 'EdgeColor', 'none'); end
xlim(ax, xr); yb = ylim(ax); if yb(2) <= 1, ylim(ax, [0 1]); end
nice(ax, 'summed t of the strongest cluster (left: negative, right: positive)', 'number of swaps');
none = sum(nulP(1:done) == 0 & nulN(1:done) == 0);
title(ax, {sprintf('The strongest clusters of %d of %d swaps', done, nS), ...
           sprintf('%d swaps without any cluster are not shown', none)}, 'FontWeight', 'normal');
if p.wait, drawnow; end
end

function tmapplot(ax, T, M, strong, tms, labT, ord, tl)
% t for channel x time, channels front to back; points outside M faded,
% M outlined thin, strong outlined thick
hold(ax, 'on');
im = imagesc(ax, tms, 1:numel(ord), T(ord, :));
if ~isempty(M), im.AlphaData = 0.35 + 0.65 * M(ord, :); end
outline(ax, M, ord, tms, 1);
outline(ax, strong, ord, tms, 2.5);
set(ax, 'YDir', 'reverse', 'YTick', 1:numel(ord), 'YTickLabel', labT(ord), 'FontSize', 7, 'TickDir', 'out', 'Box', 'off');
dt = 1; if numel(tms) > 1, dt = tms(2) - tms(1); end
xlim(ax, [tms(1) tms(end)] + [-0.5 0.5] * dt); ylim(ax, [0.5 numel(ord) + 0.5]);
clim(ax, [-tl tl]); colormap(ax, diverging());
xlabel(ax, 'time (ms)'); ylabel(ax, 'channel (front to back)');
cb = colorbar(ax); cb.Label.String = 't';
end

function outline(ax, M, ord, tms, lw)
if isempty(M) || ~any(M(:)) || numel(tms) < 2, return; end
dt = tms(2) - tms(1);
Q = false(size(M) + 2); Q(2:end-1, 2:end-1) = M(ord, :);   % padded, so every outline is closed
contour(ax, [tms(1) - dt tms tms(end) + dt], 0:numel(ord) + 1, double(Q), [0.5 0.5], 'LineColor', 'k', 'LineWidth', lw);
end

function neighbourplot(ax, lay, labT, Nb, ch)
hold(ax, 'on');
[~, il] = ismember(labT, lay.label); xy = lay.pos(il, :);
for k = 1:numel(lay.outline), plot(ax, lay.outline{k}(:, 1), lay.outline{k}(:, 2), 'Color', [0.6 0.6 0.6]); end
[a, b] = find(triu(Nb));
for k = 1:numel(a), plot(ax, xy([a(k) b(k)], 1), xy([a(k) b(k)], 2), 'Color', [0.55 0.7 0.9]); end
for k = find(Nb(ch, :)), plot(ax, xy([ch k], 1), xy([ch k], 2), 'k', 'LineWidth', 2); end
for k = 1:numel(labT)
    text(ax, xy(k, 1), xy(k, 2), labT{k}, 'FontSize', 7, 'HorizontalAlignment', 'center', ...
         'BackgroundColor', 'w', 'Margin', 0.5, 'FontWeight', iff(k == ch, 'bold', 'normal'));
end
axis(ax, 'equal', 'off');
end

function [fig, lo] = stationfig(fig, p, rows, cols)
% one window for all steps, cleared for each
if isempty(fig) || ~isgraphics(fig)
    fig = figure('Name', 'Cluster test, step by step', 'Color', 'w', 'Position', [60 80 1200 600], ...
                 'Visible', iff(p.wait, 'on', 'off'));
end
clf(fig);
lo = tiledlayout(fig, rows, cols, 'TileSpacing', 'compact', 'Padding', 'compact');
if p.wait, figure(fig); end
end

function savestep(fig, p, k)
if p.wait, drawnow; end
if isempty(p.figures) || ~isgraphics(fig), return; end
exportgraphics(fig, fullfile(p.figures, sprintf('tutorial_step%04.1f.png', k)), 'Resolution', 110);
end

function nice(ax, xl, yl)
set(ax, 'Box', 'off', 'TickDir', 'out', 'FontSize', 9);
xlabel(ax, xl); ylabel(ax, yl);
end

function yl = range3(Y)
yl = [min(Y(:)) max(Y(:))]; yl = yl + [-0.08 0.08] * max(diff(yl), eps);
end

function header(k, s)
fprintf('\n==== STEP %d of 8. %s ====\n\n', k, s);
end

function para(s)
% print a paragraph, wrapped at about 90 characters
fprintf('%s\n\n', wrap(s, '  '));
end

function para2(s)
fprintf('%s\n', strtrim(wrap(s, '     ')));
end

function out = wrap(s, ind)
w = strsplit(strtrim(s), ' '); out = ''; line = ind;
for k = 1:numel(w)
    if numel(line) + numel(w{k}) > 90 && numel(line) > numel(ind)
        out = [out line newline]; line = ind; %#ok<AGROW>
    end
    if numel(line) > numel(ind), line = [line ' ']; end %#ok<AGROW>
    line = [line w{k}]; %#ok<AGROW>
end
out = [out line];
end

function goon(p)
if p.wait, input('  [Enter to go on] ', 's'); fprintf('\n'); end
end

function x = asknumber(p, q)
x = [];
fprintf('%s\n', wrap(q, '  '));
if ~p.wait, fprintf('  (no answer, the script runs without stops)\n'); return; end
x = str2double(input('  > ', 's'));
if isnan(x), x = []; fprintf('  No number, never mind.\n'); end
end

function k = askletter(p, q, n)
k = [];
if ~p.wait, return; end
s = lower(strtrim(input(q, 's')));
if ~isempty(s) && s(1) >= 'a' && s(1) < 'a' + n, k = s(1) - 'a' + 1; end
end

function c = diverging()
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
