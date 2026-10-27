function out = cpsy1197_preprocess(subjectFile, params)
% CPSY1197_PREPROCESS  Preprocessing pipeline for CPSY 1197, ERP CORE data:
% the N170, P3b and N400 experiments.
%
%   out = cpsy1197_preprocess(subjectFile)
%   out = cpsy1197_preprocess(subjectFile, params)
%
% STRUCTURE
%   0  Look            what is in the file, and which experiment it is
%   1  Low-pass        30 Hz, on the CONTINUOUS data
%   2  Downsample      1024 Hz is more than this needs and slows everything
%   3  High-pass       0.1 Hz, removes slow drift, on the CONTINUOUS data
%   4  Bad channels    look, name the broken ones, take them out
%   5  Eye artifacts   ICA on the good channels, you pick the components
%   6  Re-reference    built from good channels only
%   7  Rebuild         put the removed channels back, from their neighbours
%   8  Epoch           cut into trials, and baseline correct
%   9  Reject          a peak-to-peak rule, then you look at every trial left
%
% THE EXPERIMENT
%   The pipeline reads it from the file name (12_N170.set is the N170) and
%   checks it against the event codes in the file. The experiment decides
%   which codes are trials and how they group into conditions, and for the
%   N170 also the reference. Everything else is the same for all three.
%   See THE THREE EXPERIMENTS below.
%
% YOUR DECISIONS
%   Stage 4, which channels are broken.
%   Stage 5, which ICA components to remove. Usually one or two, sometimes
%            three, rarely more.
%   Stage 9, which trials are bad.
%
% WHAT COMES OUT
%   out.data   the cleaned, epoched data. Keep it on your machine.
%   out.log    every decision and every count, for your report.
%   out.avg    per-condition averages. Saved with the log to a small
%              summary .mat next to the raw data. That file is what you
%              submit through Canvas.
%
% params works like a FieldTrip cfg: a field you leave out takes the
% default listed under PARAMETERS below.
%
% CPSY 1197, Fall 2026.

if nargin < 2, params = struct(); end
if isempty(which('ft_defaults'))
    error(['FieldTrip is not on your MATLAB path. Run addpath with your ' ...
           'FieldTrip folder, then cpsy1197_check.']);
end

% A quieter FieldTrip. ft_default holds the defaults behind every cfg; these
% two settings drop the "the call to ... took" lines and the usage tracker.
% Your own settings come back when the run ends.
global ft_default %#ok<GVMIS> FieldTrip keeps its defaults in this global
ftBefore  = ft_default;
ftRestore = onCleanup(@() restoreft(ftBefore));
ft_default.showcallinfo = 'no';
ft_default.trackusage   = false;
ft_defaults;

%% --------------------------------------------------------------- PARAMETERS
% Given to you, the same for everyone in the class.
p.resamplefs  = ft_getopt(params, 'resamplefs',  256);        % Hz, 0 to skip
p.hpfreq      = ft_getopt(params, 'hpfreq',      0.1);        % Hz
p.lpfreq      = ft_getopt(params, 'lpfreq',      30);         % Hz
p.prestim     = ft_getopt(params, 'prestim',     0.2);        % s
p.poststim    = ft_getopt(params, 'poststim',    0.8);        % s
p.baseline    = ft_getopt(params, 'baseline',    [-0.2 0]);   % s
p.eventshift  = ft_getopt(params, 'eventshift',  0.026);      % s, screen delay
% The reference, the trials and the peak-to-peak limit of stage 9 depend on
% the experiment: see THE THREE EXPERIMENTS below.

p.doICA       = ft_getopt(params, 'doICA',       true);
p.icaSeed     = ft_getopt(params, 'icaSeed',     42);   % fixed, so that two people
                                                        % running the same subject
                                                        % see the same components
p.interactive = ft_getopt(params, 'interactive', true);
% The window of stage 9. It follows p.interactive, but can be switched on by
% itself: with interactive false and visualCheck true, your decisions of
% stages 4 and 5 come from the presets below and only stage 9 asks you.
p.visualCheck = ft_getopt(params, 'visualCheck', p.interactive);

% Electrode positions. The raw files carry none, so they come from
% FieldTrip's standard 10-20 template, which contains every channel of this
% montage; they rebuild removed channels at stage 7. The topographies use
% FieldTrip's EasyCap layout: the same 10-20 positions, drawn on a head with
% every one of these 30 channels inside the outline (checked).
p.elecfile    = ft_getopt(params, 'elecfile', fullfile(fileparts(which('ft_defaults')), ...
                          'template', 'electrode', 'standard_1020.elc'));
p.layout      = ft_getopt(params, 'layout',      'easycapM1.mat');

% presets, used when interactive is false (testing, or re-running a decision)
p.badChannels = ft_getopt(params, 'badChannels', {});
p.removeComps = ft_getopt(params, 'removeComps', []);
p.badTrials   = ft_getopt(params, 'badTrials',   []);   % trial numbers, as stage 9 counts them

% The three EOG channels record eye movement, not brain. They help us find
% eye artifacts at stage 5, but they never count as EEG in any computation
% below.
EOG = {'HEOG_left','HEOG_right','VEOG_lower'};

%% ---------------------------------------------------- THE THREE EXPERIMENTS
% What differs between them: which event codes are trials, how the codes
% group into conditions, how soon a correct answer must follow, the
% reference, and the peak-to-peak limit of stage 9. Everything above is
% the same for all three. All of it follows ERP CORE: the bin descriptor
% files BDF_P3.txt, BDF_N170.txt and BDF_N400.txt (codes, conditions,
% answer window) and Script 1 of each experiment (reference). In all three,
% code 201 is a correct answer and 202 a wrong one.
E = struct();

% P3b, active visual oddball. A stream of the letters A to E, one of them
% the target in each block. First digit: which letter is the target in this
% block. Second digit: which letter appeared. When the two digits match,
% the participant saw the target.
E.P3b = struct('title', 'P3b, active visual oddball', 'tag', 'P3', ...
    'conditions', struct('target',   [11 22 33 44 55], ...
                         'standard', [12:15 21 23:25 31 32 34 35 41:43 45 51:54]), ...
    'otherCodes', [], 'otherNote', '', ...
    'answerWindow', [0.2 1.0], 'refchannel', {{'P9','P10'}}, 'thrPeak2Peak', 125);

% N170, face perception. Faces, cars, and scrambled versions of both; each
% code is one picture, and the participant answers "object" or "texture".
% ERP CORE's N170 is faces minus cars.
% ERP CORE references the N170 to the average of all channels, "because the
% average reference is standard in the N170 literature" (Kappenman et al.,
% 2021; N170 Script 1). It also matters here: in these recordings faces
% minus cars is largest at P10 and P9 themselves, then PO8, so a P9/P10
% reference would subtract most of it from every channel. Here the average
% is over the good EEG channels. ERP CORE's average also includes the three
% eye channels; ours leaves them out, because here they are not cleaned at
% stage 5 and would carry the blinks into every channel.
E.N170 = struct('title', 'N170, face perception', 'tag', 'N170', ...
    'conditions', struct('faces', 1:40, 'cars', 41:80, ...
                         'scrambledFaces', 101:140, 'scrambledCars', 141:180), ...
    'otherCodes', [], 'otherNote', '', ...
    'answerWindow', [0.2 1.0], 'refchannel', 'all', 'thrPeak2Peak', 100);

% N400, word pair judgement. A prime word, then a target word that is
% related or unrelated to it. Hundreds digit: 1 prime, 2 target. Tens digit:
% 1 related pair, 2 unrelated. Ones digit: word list 1 or 2. The trials are
% the target words.
E.N400 = struct('title', 'N400, word pair judgement', 'tag', 'N400', ...
    'conditions', struct('unrelated', [221 222], 'related', [211 212]), ...
    'otherCodes', [111 112 121 122], ...
    'otherNote', 'the prime words, which come first in each pair', ...
    'answerWindow', [0.2 1.5], 'refchannel', {{'P9','P10'}}, 'thrPeak2Peak', 100);

fprintf('\n=== CPSY 1197 preprocessing ===\n%s\n\n', subjectFile);
log = struct('file', subjectFile, ...
             'runWhen', char(datetime('now','Format','yyyy-MM-dd HH:mm:ss')));

%% ------------------------------------------------------------ 0  LOOK
hdr = ft_read_header(subjectFile);
fprintf('Channels %d   Sampling rate %g Hz   Duration %.1f s\n', ...
        hdr.nChans, hdr.Fs, hdr.nSamples/hdr.Fs);

% Each participant folder can also hold ERP CORE's own processed version,
% the file with the long name ending in _weighted.set. It reads without an
% error, so check for it here rather than fail confusingly at stage 6.
if any(contains(hdr.label, 'uncorr'))
    [~, fbase] = fileparts(subjectFile);
    error(['This is ERP CORE''s processed file, not the raw recording. Use the ' ...
           'file with the short name next to it, %s.set.'], regexprep(fbase, '_shifted.*$', ''));
end

% The channel names exactly as you will type them at stage 4.
eegChans = setdiff(renamefp(hdr.label), EOG, 'stable');
eegChans = eegChans(:)';
printwrapped(sprintf('EEG (%d): ', numel(eegChans)), eegChans);
printwrapped(sprintf('Eye (%d): ', numel(EOG)), EOG);

evt = ft_read_event(subjectFile);
if isempty(evt), error('No events found. Check the path and that this is the raw .set.'); end
types = unique({evt.type});
fprintf('\nEvent types:\n');
for k = 1:numel(types)
    sel = strcmp({evt.type}, types{k});
    v   = [evt(sel).value];
    if isnumeric(v) && ~isempty(v)
        fprintf('  %-14s n=%4d  values: %s\n', types{k}, sum(sel), coderanges(v));
    else
        fprintf('  %-14s n=%4d\n', types{k}, sum(sel));
    end
end
log.nChansRaw = hdr.nChans; log.fsampleRaw = hdr.Fs; log.eventTypes = types;
log.channels  = eegChans;

% The triggers, in time order, each with its code as a number.
evt = evt(strcmp({evt.type}, 'trigger'));
evtValue = nan(1, numel(evt));
for k = 1:numel(evt)
    if isnumeric(evt(k).value) && isscalar(evt(k).value), evtValue(k) = evt(k).value; end
end
evt = evt(~isnan(evtValue)); evtValue = evtValue(~isnan(evtValue));
if isempty(evt), error('This file has no trigger codes. Check that it is a raw ERP CORE recording.'); end
[evtSample, order] = sort([evt.sample]);
evtValue = evtValue(order);

% Which experiment, and with it the trials, the reference and the
% peak-to-peak limit of stage 9.
[expName, how] = whichexperiment(subjectFile, evtValue, E);
X = E.(expName);
p.experiment   = expName;
p.conditions   = ft_getopt(params, 'conditions',   X.conditions);
p.answerWindow = ft_getopt(params, 'answerWindow', X.answerWindow);   % s
p.refchannel   = ft_getopt(params, 'refchannel',   X.refchannel);
p.thrPeak2Peak = ft_getopt(params, 'thrPeak2Peak', X.thrPeak2Peak); % uV, max minus min

fprintf('\nExperiment: %s (%s).\n', X.title, how);
fprintf('Trials, as ERP CORE defines them for this experiment:\n');
condNames = fieldnames(p.conditions);
for k = 1:numel(condNames)
    fprintf('  %-16s %s\n', readable(condNames{k}), coderanges(p.conditions.(condNames{k})));
end
if ~isempty(X.otherCodes)
    fprintf('Not trials: %s, %s.\n', coderanges(X.otherCodes), X.otherNote);
end
fprintf('A stimulus counts as a trial only if a correct answer (201) follows\nwithin %g to %g s.\n', ...
        p.answerWindow);
if isfield(params, 'eventtype') || isfield(params, 'eventvalue')
    fprintf(['NOTE: params.eventtype and params.eventvalue are not used any more.\n' ...
             'The trials come from the experiment, as listed above.\n']);
end
log.experiment      = expName;
log.experimentTitle = X.title;
log.params          = p;

%% ------------------------------------------------------------ 1  LOW-PASS
% On the continuous data, at the native rate. The low pass removes the
% high-frequency noise we never analyse. It comes before the downsampling
% because that is the order of the lab's TNU/SPM pipeline: low pass,
% downsample, high pass. It is not the only protection against aliasing:
% ft_resampledata applies its own anti-aliasing filter when it resamples
% (help ft_resampledata).

stage(1, 'Low-pass filter');
cfg = []; cfg.dataset = subjectFile; cfg.continuous = 'yes';
dataCont = ft_preprocessing(cfg);

% The ERP CORE files write the two frontal channels as FP1 and FP2. Every
% standard layout and electrode template writes them Fp1 and Fp2. Rename them
% once, here, so that positions and topographies can find them.
dataCont.label = renamefp(dataCont.label);

cfg = []; cfg.lpfilter='yes'; cfg.lpfreq=p.lpfreq; cfg.lpfilttype='firws';
dataCont = ft_preprocessing(cfg, dataCont);
fprintf('Low-pass filtered at %g Hz.\n', p.lpfreq);

%% ------------------------------------------------------------ 2  DOWNSAMPLE
% 1024 Hz is more than an ERP needs. At 256 Hz everything after this runs
% about four times faster, and the ICA at stage 5 would not finish on a
% laptop otherwise.

stage(2, 'Downsample');
if p.resamplefs > 0 && p.resamplefs < hdr.Fs
    cfg = []; cfg.resamplefs = p.resamplefs; cfg.detrend = 'no';
    dataCont = ft_resampledata(cfg, dataCont);
    % One continuous stretch, starting at its first sample. Saying so here
    % saves FieldTrip from guessing it later, with a warning.
    dataCont.sampleinfo = [1 size(dataCont.trial{1}, 2)];
    fprintf('Resampled %g -> %g Hz.\n', hdr.Fs, p.resamplefs);
else
    fprintf('Skipped, data stay at %g Hz.\n', dataCont.fsample);
end
log.fsample = dataCont.fsample;

%% ------------------------------------------------------------ 3  HIGH-PASS
% 0.1 Hz removes the slow drift that would otherwise swamp the baseline. A
% high pass this low reaches across several seconds of data, which is why it
% runs on CONTINUOUS data, as in both reference pipelines. The FieldTrip ERP
% tutorial filters after epoching instead; that works for their 1 s trials,
% not for 0.1 Hz. It comes after the downsampling because the filter is four
% times shorter at 256 Hz; the result is the same, only faster.

stage(3, 'High-pass filter');
cfg = []; cfg.hpfilter='yes'; cfg.hpfreq=p.hpfreq; cfg.hpfilttype='firws';
dataCont = ft_preprocessing(cfg, dataCont);
fprintf('High-pass filtered at %g Hz.\n', p.hpfreq);
log.filter = struct('lp',p.lpfreq,'hp',p.hpfreq,'type','firws', ...
                    'order','low pass, downsample, high pass');

%% ------------------------------------------------------------ 4  BAD CHANNELS
% A broken channel is an electrode that did not record brain: flat, buzzing
% with noise, or jumping by hundreds of microvolts. You find it by looking,
% the way FieldTrip's EEG tutorials do it: page through the recording, then
% type the names. There is deliberately no table of numbers here. We tested
% the usual ones (standard deviation, correlation with the neighbours)
% against the channels the ERP CORE authors interpolated in these very
% recordings. Both caught the obvious failures, which you see at a glance
% anyway, and both flagged healthy channels.
%
% A named channel is taken out of the data now, so that it plays no part in
% the ICA (stage 5) or in the reference (stage 6). It is rebuilt from its
% neighbours at stage 7. FieldTrip's ICA tutorial gives the same order:
% remove bad channels before the decomposition, repair them after it.

stage(4, 'Bad channels');
elec = ft_read_sens(p.elecfile, 'senstype', 'eeg');
cfg  = []; cfg.layout = p.layout; cfg.channel = eegChans;
layout = ft_prepare_layout(cfg);

if p.interactive
    fprintf(['Opening the browser: 30 s per page, every channel on the same\n' ...
             '+/-100 uV scale, the eye channels at the bottom. Page through the\n' ...
             'whole recording, then close the window to continue.\n']);
    cfg = []; cfg.viewmode = 'vertical'; cfg.continuous = 'yes';
    cfg.blocksize = 30; cfg.ylim = [-100 100]; cfg.plotevents = 'no';
    cfg = ft_databrowser(cfg, dataCont); %#ok<NASGU>  % with an output, it waits for you
    badChans = askchannels(eegChans, EOG);
else
    [badChans, unknown] = matchchannels(cellstr(p.badChannels), eegChans);
    if ~isempty(unknown)
        error('Not an EEG channel in this recording: %s.', strjoin(unknown, ', '));
    end
    fprintf('Non-interactive run, preset bad channels: %s\n', listornone(badChans));
end

goodChans = setdiff(eegChans, badChans, 'stable');
refUsed   = referencechannels(p.refchannel, goodChans);
refIsAll  = ischar(p.refchannel) && strcmpi(p.refchannel, 'all');   % average reference
refLost   = {};
if ~refIsAll, refLost = setdiff(cellstr(p.refchannel), refUsed, 'stable'); end
if isempty(refUsed)
    error(['Both reference channels (%s) are marked broken, which leaves no ' ...
           'reference. Look at them again. If they really are both broken, ' ...
           'ask before going on.'], strjoin(cellstr(p.refchannel), ' and '));
end

if isempty(badChans)
    fprintf('No channels marked.\n');
else
    fprintf('Marked broken: %s. Removed now, rebuilt at stage 7.\n', strjoin(badChans, ', '));
    cfg = []; cfg.channel = [{'all'}, strcat('-', badChans)];
    dataCont = ft_selectdata(cfg, dataCont);
    if numel(badChans) > 3
        warning(['You marked %d channels. Most of these recordings have none ' ...
                 'or one, occasionally two. Look again before going on.'], numel(badChans));
    end
end
if ~isempty(refLost)
    fprintf(['\nREFERENCE CHANGES. %s is one of the reference channels and you marked\n' ...
             'it broken, so at stage 6 the reference becomes %s ALONE instead of\n' ...
             'the average of %s. Your data will then differ from your\n' ...
             'classmates''. Say so in your log.\n'], strjoin(refLost, ' and '), ...
             strjoin(refUsed, ' and '), strjoin(cellstr(p.refchannel), ' and '));
end
log.badChannels = badChans;

%% ------------------------------------------------------------ 5  EYE ARTIFACTS
% ICA on the continuous data, before re-referencing and epoching, following
% the FieldTrip ICA tutorial. It sees the good channels only: the broken ones
% left at stage 4, so they cannot produce components of their own. It
% collects each kind of eye artifact into a component of its own: the
% blinks, and the horizontal eye movements.
%
% Be stingy here. Every component you remove takes real signal with it, and
% over-removal is invisible afterwards: the data look clean because something
% that belonged there is gone. Usually one or two components, sometimes
% three, rarely more. If you cannot say what artifact a component is, leave
% it in. Stage 9 is the safety net for whatever remains.
%
% So that you can see what the correction bought you, the pipeline keeps a
% copy of the data from this point WITHOUT the correction. At stage 9 both
% versions pass through the same threshold and you get both counts.

stage(5, 'Blinks and eye movements (ICA)');
cfg = []; cfg.channel = goodChans; eeg = ft_selectdata(cfg, dataCont);
cfg = []; cfg.channel = EOG;       eog = ft_selectdata(cfg, dataCont);
eegNoICA = eeg;    % the uncorrected copy, for the stage 9 comparison

if p.doICA
    % runica starts from the same weights every time, but it visits the data
    % in a random order at every step. cfg.randomseed, FieldTrip's own
    % option, fixes that order, so the same recording gives the same
    % components, and the seed is stored in comp.cfg.callinfo.
    cfg = []; cfg.method = 'runica'; cfg.runica.maxsteps = 128;
    cfg.randomseed = p.icaSeed;
    comp = ft_componentanalysis(cfg, eeg);

    % Correlate every component with the eye channels. A blink component
    % follows the vertical EOG, an eye-movement component the horizontal
    % one, so a high correlation is the strongest single piece of evidence
    % you get. The eye channels are built the way ERP CORE builds them:
    % vertical as the electrode below the eye minus Fp2 above it, horizontal
    % as left minus right.
    % The first and last ten seconds are left out of the correlation: the
    % high-pass filter rings at the edges of the recording, and that one
    % transient can hand a meaningless component a large r.
    veog  = getchan(dataCont, 'VEOG_lower');
    above = intersect({'Fp2','Fp1'}, goodChans, 'stable');
    if ~isempty(above), veog = veog - getchan(dataCont, above{1}); end
    heog  = getchan(dataCont, 'HEOG_left') - getchan(dataCont, 'HEOG_right');
    edgeS = round(10 * log.fsample);
    mid   = edgeS+1 : numel(veog)-edgeS;
    veog  = veog(mid); heog = heog(mid);
    nC    = numel(comp.label);
    rV = zeros(nC,1); rH = zeros(nC,1);
    for c = 1:nC
        R = corrcoef(comp.trial{1}(c,mid), veog); rV(c) = R(1,2);
        R = corrcoef(comp.trial{1}(c,mid), heog); rH(c) = R(1,2);
    end
    [~,ordV] = sort(max(abs([rV rH]),[],2), 'descend');
    fprintf('\nCorrelation of each component with the eye channels:\n');
    fprintf('%-6s %9s %9s\n','comp','r(VEOG)','r(HEOG)');
    for c = ordV(1:min(8,nC))'
        fprintf('%-6d %9.2f %9.2f\n', c, rV(c), rH(c));
    end
    fprintf(['A blink component has |r(VEOG)| far above the rest, a frontal\n' ...
             'topography, and a time course of isolated spikes. An eye-movement\n' ...
             'component has a high |r(HEOG)|, a map positive on one side of the\n' ...
             'forehead and negative on the other, and a time course of steps.\n' ...
             'All three signs, not one of the three.\n']);
    log.icaVeogCorr = rV; log.icaHeogCorr = rH;

    if p.interactive
        figure('Name','ICA component topographies');
        cfg = []; cfg.component = 1:min(20,nC); cfg.layout = layout; cfg.comment = 'no';
        cfg.dataname = 'ICA';    % titles read "ICA component 1", not the variable name
        ft_topoplotIC(cfg, comp);
        fprintf(['\nOpening the component browser. Check topography AND time course,\n' ...
                 'then close the browser to continue.\n']);
        cfg = []; cfg.viewmode = 'component'; cfg.layout = layout; cfg.blocksize = 10;
        cfg.plotevents = 'no';
        cfg = ft_databrowser(cfg, comp); %#ok<NASGU>  % with an output, it waits for you
        compsOut = askcomponents(nC);
    else
        compsOut = p.removeComps(:)';
        if any(compsOut < 1 | compsOut > nC | compsOut ~= round(compsOut))
            error('Component numbers must be whole numbers between 1 and %d.', nC);
        end
        if isempty(compsOut), s = 'none'; else, s = mat2str(compsOut); end
        fprintf('Non-interactive run, removing preset components: %s\n', s);
    end

    if numel(compsOut) > 3
        warning(['You are removing %d components. Usually one or two is right, ' ...
                 'sometimes three, rarely more. Write down why each one goes.'], numel(compsOut));
    end

    if ~isempty(compsOut)
        cfg = []; cfg.component = compsOut;
        eeg = ft_rejectcomponent(cfg, comp, eeg);
        fprintf('Removed component(s) %s.\n', mat2str(compsOut));
    else
        fprintf('Nothing removed.\n');
    end
    log.icaRemoved = compsOut;
    log.blinkHandling = sprintf('ICA, removed %s', mat2str(compsOut));
else
    fprintf('ICA skipped (params.doICA = false).\n');
    log.icaRemoved = [];
    log.blinkHandling = 'none, ICA disabled';
end

%% ------------------------------------------------------------ 6  RE-REFERENCE
% P3b and N400: the average of P9 and P10, which is Luck's current
% preference for ERP CORE, with linked mastoids as the second choice.
% N170: the average of all good EEG channels, as ERP CORE does for the N170;
% THE THREE EXPERIMENTS above says why.
%
% The reference is built from good channels only, because the broken ones
% left at stage 4. With an average reference that matters for every
% channel: one broken electrode would be averaged into all of them
% ("by subtracting an average, noisy periods present in only few EEG
% channels will spread to all other channels", FieldTrip, Madrid 2019
% cleaning tutorial). With P9 and P10 it matters only if one of those two is
% the broken one, and then the other one alone becomes the reference.
% The eye channels stay as recorded.

stage(6, 'Re-referencing');
cfg = []; cfg.reref = 'yes'; cfg.refchannel = refUsed; cfg.refmethod = 'avg';
eeg      = ft_preprocessing(cfg, eeg);
eegNoICA = ft_preprocessing(cfg, eegNoICA);
if isempty(refLost)
    fprintf('Referenced to %s.\n', describeref(p.refchannel, refUsed));
else
    fprintf('REFERENCED TO %s ALONE (%s marked broken).\n', ...
            strjoin(refUsed, ' and '), strjoin(refLost, ' and '));
end
log.reference          = refUsed;
log.referenceRequested = p.refchannel;

%% ------------------------------------------------------------ 7  REBUILD
% The channels removed at stage 4 come back, estimated from their
% neighbours, which by now are corrected for eye artifacts and re-referenced.
% Spherical spline interpolation (Perrin et al., 1989), the method ERP CORE
% used for these recordings. FieldTrip rebuilds channels that are absent
% from the data from a complete set of electrode positions, here its 10-20
% template (help ft_channelrepair).

stage(7, 'Rebuilding removed channels');
if ~isempty(badChans)
    cfg = []; cfg.method = 'spline'; cfg.missingchannel = badChans;
    cfg.elec = elec; cfg.senstype = 'eeg';
    eeg      = ft_channelrepair(cfg, eeg);
    eegNoICA = ft_channelrepair(cfg, eegNoICA);
    eeg      = montageorder(eeg,      eegChans);
    eegNoICA = montageorder(eegNoICA, eegChans);
    fprintf('Rebuilt from their neighbours: %s\n', strjoin(badChans, ', '));
    log.badHandling = 'removed at stage 4, rebuilt by spherical spline after re-referencing';
else
    fprintf('Nothing to rebuild.\n'); log.badHandling = 'none needed';
end

data      = ft_appenddata([], eeg,      eog);
dataNoICA = ft_appenddata([], eegNoICA, eog);
data.fsample = log.fsample; dataNoICA.fsample = log.fsample;

%% ------------------------------------------------------------ 8  EPOCH
% Which stimuli are trials. ERP CORE's rule, from its BDF files: a stimulus
% counts only if the very next event is a correct answer, code 201, within
% the answer window. On the others we cannot tell whether the participant
% processed the stimulus as the task intended.
%
% Each event code marks the moment the computer sent the stimulus to the
% screen. The screen showed it 26 ms later: the ERP CORE lab measured the
% delay with a photosensor and shifts every stimulus code by that much
% (README of each experiment, Script 1), in whole samples of the recording,
% rounded down: 26 samples at 1024 Hz. The same here, so that the trials are
% exactly ERP CORE's. The answer window counts from the shifted time, as in
% ERP CORE. The events were read from the raw file at its original rate
% while the data now run at 256 Hz, so each shifted event time,
% (sample-1)/rate, is converted to a sample at the new rate.

stage(8, 'Epoching and baseline');
c          = struct2cell(p.conditions);
trialCodes = unique([c{:}]);
shiftS     = floor(p.eventshift * hdr.Fs);   % the shift, in samples of the recording
isStim     = ismember(evtValue, trialCodes);
nextValue  = [evtValue(2:end) NaN];
answerTime = ([evtSample(2:end) NaN] - (evtSample + shiftS)) / hdr.Fs;
isTrial    = isStim & nextValue == 201 & ...
             answerTime >= p.answerWindow(1) & answerTime <= p.answerWindow(2);
if ~any(isTrial), error('No stimulus in this file has a correct answer in time.'); end

tEvt   = (evtSample(isTrial) + shiftS - 1) / hdr.Fs;
smpNew = round(tEvt * log.fsample) + 1;
preS   = round(p.prestim  * log.fsample);
postS  = round(p.poststim * log.fsample);
trl    = [smpNew(:) - preS, smpNew(:) + postS, ...
          repmat(-preS, numel(smpNew), 1), evtValue(isTrial)'];

nTotal = size(data.trial{1}, 2);
inside = trl(:,1) >= 1 & trl(:,2) <= nTotal;
if any(~inside)
    fprintf('Dropped %d trial(s) that ran past the edge of the recording.\n', sum(~inside));
end
trl = trl(inside,:);

cfg = []; cfg.trl = trl;
data      = ft_redefinetrial(cfg, data);
dataNoICA = ft_redefinetrial(cfg, dataNoICA);

cfg = []; cfg.demean='yes'; cfg.baselinewindow=p.baseline;
data      = ft_preprocessing(cfg, data);
dataNoICA = ft_preprocessing(cfg, dataNoICA);

nInit = numel(data.trial);
nPer  = cellfun(@(cn) sum(ismember(trl(:,4), p.conditions.(cn))), condNames);
fprintf('%d trials, %g to %g s, baseline %g to %g s, events shifted %+g ms.\n', ...
        nInit, -p.prestim, p.poststim, p.baseline(1), p.baseline(2), 1000*p.eventshift);
fprintf('  %s\n', strjoin(arrayfun(@(k) sprintf('%s %d', readable(condNames{k}), nPer(k)), ...
        1:numel(condNames), 'UniformOutput', false), '   '));
fprintf('  %d of %d stimuli are not trials: no correct answer within %g to %g s.\n', ...
        sum(isStim & ~isTrial), sum(isStim), p.answerWindow);
log.nStimuli         = sum(isStim);
log.nNoCorrectAnswer = sum(isStim & ~isTrial);
log.answerWindow     = p.answerWindow;
log.nTrialsInitial   = nInit;
log.nTrialsPerConditionInitial = cell2struct(num2cell(nPer(:)), condNames, 1);
log.epochWindow      = [-p.prestim p.poststim];
log.baselineWindow   = p.baseline;
log.eventShift       = p.eventshift;
log.eventShiftSamples = shiftS;

%% ------------------------------------------------------------ 9  REJECT
% Two steps, and they do different jobs.
%
% First, a rule removes the obvious ones. For each trial it takes the
% largest peak-to-peak swing (max minus min) of any EEG channel; a trial
% above the limit of your experiment is out. The limit is the median of the
% ones the ERP CORE authors chose per participant for these recordings
% (AR_Parameters_for_MW_CRAP_*.xlsx; in FieldTrip ft_artifact_threshold,
% cfg.artfctdef.threshold.range). It is the same for every participant, so
% you do not tune it. A rule is fast and identical for everyone, but it
% knows one thing only: how far a trace swings.
%
% Second, YOU look at every trial that is left and mark the ones that look
% wrong although they swing less: a slow drift, a burst of muscle, a jump
% in one channel, a blink the ICA left behind. That list is your decision.
% The window shows no condition, so you judge a trial without knowing which
% average it will land in. Do not look at the averages first.
%
% The rule also runs on the copy that never saw the ICA correction. The
% difference between the two counts is what stage 5 bought you.

stage(9, 'Rejecting bad trials');
p2p      = peak2peak(data,      eegChans);
p2pNoICA = peak2peak(dataNoICA, eegChans);
auto      = find(p2p      > p.thrPeak2Peak)';
autoNoICA = find(p2pNoICA > p.thrPeak2Peak)';

q = pct(p2p, [50 90 95]);
fprintf('Peak-to-peak per trial (uV): median %.0f, 90%% %.0f, 95%% %.0f, largest %.0f\n', ...
        q, max(p2p));
fprintf('The rule removes the %d of %d trials that swing more than %g uV:\n', ...
        numel(auto), nInit, p.thrPeak2Peak);
if isempty(auto)
    fprintf('  none\n');
else
    printwrapped('  ', arrayfun(@num2str, auto, 'UniformOutput', false));
end

if p.doICA
    fprintf('\n                     without ICA    with ICA\n');
    fprintf('   trials removed     %3d (%2.0f%%)      %3d (%2.0f%%)\n', ...
            numel(autoNoICA), 100*numel(autoNoICA)/nInit, numel(auto), 100*numel(auto)/nInit);
    fprintf('   recovered                        %d trials\n', numel(autoNoICA) - numel(auto));
end

if p.visualCheck
    fprintf(['\nNow look at the rest. One trial per screen, all channels, same scale.\n' ...
             '  Next, previous trial : right and left arrow keys\n' ...
             '  Mark trial as bad    : b   (the trial goes blank)\n' ...
             '  Take the mark back   : g\n' ...
             '  Finish               : q, or the quit button\n' ...
             'A trial that is blank when you arrive was removed by the rule; g does not\n' ...
             'bring it back. Do not click on a trace, that only hides the trace. Closing\n' ...
             'the window with the mouse instead of q keeps every trial and forgets your\n' ...
             'marks.\n']);
    % Only the EEG channels are drawn, trial numbers are the ones of the
    % report. The scale is fixed so that a trial that swings as much as the
    % rule allows just fills its box: anything that spills over its
    % neighbours is large.
    cfg = []; cfg.channel = eegChans;
    lookIn = ft_selectdata(cfg, data);
    cfg = [];
    cfg.method      = 'trial';
    cfg.trials      = setdiff(1:nInit, auto);   % the rest starts as included
    cfg.keepchannel = 'yes';
    cfg.ylim        = [-1 1] * p.thrPeak2Peak / 2;
    cfg.box         = 'yes';
    lookOut = ft_rejectvisual(cfg, lookIn);
    gone = find(~ismember(lookIn.sampleinfo(:,1), lookOut.sampleinfo(:,1)))';
    byHand = setdiff(gone, auto);              % the rule's removals always stand
else
    byHand = unique(p.badTrials(:))';
    if any(byHand < 1 | byHand > nInit | byHand ~= round(byHand))
        error('params.badTrials must be trial numbers between 1 and %d.', nInit);
    end
    byHand = setdiff(byHand, auto);
    fprintf('\nNon-interactive run, preset bad trials: %s\n', ...
            listornone(arrayfun(@num2str, byHand, 'UniformOutput', false)));
end

if p.visualCheck
    fprintf('\nBy hand you removed %d trials:\n', numel(byHand));
    if isempty(byHand)
        fprintf('  none\n');
    else
        printwrapped('  ', arrayfun(@num2str, byHand, 'UniformOutput', false));
    end
end

rejected = union(auto, byHand);
cfg = []; cfg.trials = setdiff(1:nInit, rejected);
data = ft_selectdata(cfg, data);

log.rejection = struct( ...
  'thrPeak2Peak', p.thrPeak2Peak, 'nPeak2Peak', numel(auto), ...
  'idxByRule', auto, 'idxByHand', byHand, 'idxRejected', rejected, ...
  'p2p', single(p2p), 'p2pWithoutICA', single(p2pNoICA));
log.comparison = struct( ...
  'rejectedWithoutICA', numel(autoNoICA), 'rejectedWithICA', numel(auto), ...
  'recovered', numel(autoNoICA) - numel(auto), 'nTrials', nInit);
log.nRejectedThreshold = numel(auto);
log.nRejectedByHand    = numel(byHand);
log.nTrialsFinal       = numel(data.trial);
log.nTrialsRejected    = nInit - log.nTrialsFinal;
log.pctRejected        = 100 * log.nTrialsRejected / max(nInit,1);
fprintf('\nKept %d of %d trials (%.1f%% rejected: %d by the rule, %d by hand).\n', ...
        log.nTrialsFinal, nInit, log.pctRejected, numel(auto), numel(byHand));

%% ------------------------------------------------- AVERAGES AND SUMMARY FILE
% Per-condition averages, channels by timepoints. Together with the log they
% go into one small .mat file next to the raw data. That file is what you
% submit; the epoched data stays on your machine, you need it in November.

fprintf('\n--- Averages and summary file ---\n');
avg = struct();
for k = 1:numel(condNames)
    cn  = condNames{k};
    idx = find(ismember(data.trialinfo(:,1), p.conditions.(cn)));
    if isempty(idx)
        fprintf('  %-16s   0 trials left, no average\n', readable(cn));
        log.nTrialsPerCondition.(cn) = 0; continue
    end
    cfg = []; cfg.trials = idx; cfg.channel = eegChans;
    tl  = ft_timelockanalysis(cfg, data);
    avg.(cn) = struct('label',{tl.label}, 'time',tl.time, 'avg',single(tl.avg), ...
                      'nTrials',numel(idx), 'dimord','chan_time');
    log.nTrialsPerCondition.(cn) = numel(idx);
    fprintf('  %-16s %3d trials averaged\n', readable(cn), numel(idx));
end

[fdir, fbase] = fileparts(subjectFile);
summaryFile = fullfile(fdir, [fbase '_summary.mat']);
log.summaryFile = summaryFile;
summary = struct('log', log, 'avg', avg);
save(summaryFile, '-struct', 'summary');
d = dir(summaryFile);
fprintf('Saved %s (%.0f kB).\n', summaryFile, d.bytes/1024);

%% --------------------------------------------------------------------- DONE
out = struct('data', data, 'log', log, 'avg', avg);
fprintf('\nDone. Keep the cleaned data on your machine, then print your report:\n');
fprintf('  save(''%s'', ''-struct'', ''out'');\n', fullfile(fdir, [fbase '_clean.mat']));
fprintf('  cpsy1197_report(out, ''Your Name'')\n\n');
end

% ---------------------------------------------------------------------------
function stage(n, name)
% One consistent banner per stage, so you always know where you are.
fprintf('\n--- %d. %s ---\n', n, name);
end

% ---------------------------------------------------------------------------
function [name, how] = whichexperiment(file, values, E)
% The experiment of a recording: from the file name, checked against the
% event codes. A recording fits an experiment when every code in it belongs
% to that experiment and every trial code of the experiment occurs in it.
names = fieldnames(E)';
codes = unique(values);
fits  = false(size(names)); named = false(size(names));
[~, base] = fileparts(file);
for k = 1:numel(names)
    X = E.(names{k});
    c = struct2cell(X.conditions); trialCodes = unique([c{:}]);
    fits(k)  = all(ismember(codes, [trialCodes X.otherCodes 201 202])) && ...
               all(ismember(trialCodes, codes));
    named(k) = ~isempty(regexpi(base, ['(^|[_\-])' X.tag '($|[_\-])'], 'once'));
end
if sum(named) == 1
    name = names{named};
    if fits(named), how = 'from the file name; the event codes agree'; return; end
    if sum(fits) == 1
        error(['The file name says %s, but the event codes in it are those of the %s ' ...
               'experiment. Check that you copied the right file.'], name, names{fits});
    end
    error(['The file name says %s, but its event codes match none of the three ' ...
           'experiments. Check that this is a raw ERP CORE recording.'], name);
elseif sum(fits) == 1
    name = names{fits};
    how  = 'from the event codes; the file name does not say';
else
    error(['Cannot tell which experiment this file is. ERP CORE names its ' ...
           'recordings like 12_P3.set, 12_N170.set or 12_N400.set.']);
end
end

% ---------------------------------------------------------------------------
function s = coderanges(v)
% Codes as a short list: 11 12 13 14 15 21 becomes "11-15 21". Runs of three
% or more become ranges.
v = unique(v(:)'); parts = {}; k = 1;
while k <= numel(v)
    j = k;
    while j < numel(v) && v(j+1) == v(j) + 1, j = j + 1; end
    if j - k >= 2
        parts{end+1} = sprintf('%d-%d', v(k), v(j)); %#ok<AGROW>
    else
        parts = [parts, arrayfun(@(x) sprintf('%d', x), v(k:j), 'UniformOutput', false)]; %#ok<AGROW>
    end
    k = j + 1;
end
s = strjoin(parts, ' ');
end

% ---------------------------------------------------------------------------
function s = readable(name)
% A condition's name for the console: scrambledFaces as "scrambled faces".
s = lower(regexprep(name, '([a-z])([A-Z])', '$1 $2'));
end

% ---------------------------------------------------------------------------
function labels = renamefp(labels)
labels = strrep(strrep(labels, 'FP1', 'Fp1'), 'FP2', 'Fp2');
end

% ---------------------------------------------------------------------------
function printwrapped(prefix, words)
% A list of names on as many lines as it needs, under its prefix.
pad  = repmat(' ', 1, numel(prefix));
line = prefix; fresh = true;
for k = 1:numel(words)
    if ~fresh && numel(line) + 1 + numel(words{k}) > 72
        fprintf('%s\n', line); line = pad; fresh = true;
    end
    if fresh, line = [line words{k}]; else, line = [line ' ' words{k}]; end %#ok<AGROW>
    fresh = false;
end
fprintf('%s\n', line);
end

% ---------------------------------------------------------------------------
function [matched, unknown] = matchchannels(names, labels)
% Case does not matter: po8 and PO8 are the same channel.
matched = {}; unknown = {};
for k = 1:numel(names)
    i = find(strcmpi(labels, names{k}), 1);
    if isempty(i)
        unknown{end+1} = names{k}; %#ok<AGROW>
    elseif ~any(strcmp(matched, labels{i}))
        matched{end+1} = labels{i}; %#ok<AGROW>
    end
end
end

% ---------------------------------------------------------------------------
function bad = askchannels(eegChans, eogChans)
% Ask until every name typed is an EEG channel of this recording.
while true
    s = input('Broken channels, comma separated (Enter for none): ', 's');
    names = strtrim(strsplit(s, {',', ' ', ';'}));
    names = names(~cellfun(@isempty, names));
    [bad, unknown] = matchchannels(names, eegChans);
    if isempty(unknown), return; end
    isEye = ismember(lower(unknown), lower(eogChans));
    if any(isEye)
        fprintf('%s: the eye channels are not EEG and are never marked here.\n', ...
                strjoin(unknown(isEye), ', '));
    end
    if any(~isEye)
        fprintf('Not a channel in this recording: %s. The names are listed at the top of the run.\n', ...
                strjoin(unknown(~isEye), ', '));
    end
end
end

% ---------------------------------------------------------------------------
function comps = askcomponents(nComp)
% Ask until the answer is a list of component numbers, or nothing.
while true
    s = input('Components to remove, comma separated (Enter for none): ', 's');
    tok = strtrim(strsplit(s, {',', ' ', ';'}));
    tok = tok(~cellfun(@isempty, tok));
    comps = str2double(tok);
    ok = ~isnan(comps) & comps == round(comps) & comps >= 1 & comps <= nComp;
    if all(ok), comps = unique(comps, 'stable'); return; end
    fprintf('Type component numbers between 1 and %d, for example 1 or 1, 4.\n', nComp);
end
end

% ---------------------------------------------------------------------------
function used = referencechannels(wanted, good)
% The reference channels that are still there. 'all' is an average reference
% over every good EEG channel.
if ischar(wanted) && strcmpi(wanted, 'all')
    used = good(:)';
else
    used = intersect(cellstr(wanted), good, 'stable');
    used = used(:)';
end
end

% ---------------------------------------------------------------------------
function s = describeref(wanted, used)
if ischar(wanted) && strcmpi(wanted, 'all')
    s = sprintf('the average of all %d good EEG channels', numel(used));
else
    s = strjoin(used, ' + ');
end
end

% ---------------------------------------------------------------------------
function s = listornone(names)
if isempty(names), s = 'none'; else, s = strjoin(names, ', '); end
end

% ---------------------------------------------------------------------------
function data = montageorder(data, labels)
% ft_channelrepair appends rebuilt channels at the end; put every channel
% back where it sits in the montage, so all participants share one order.
[~, idx] = ismember(labels, data.label);
data.label = data.label(idx);
for t = 1:numel(data.trial)
    data.trial{t} = data.trial{t}(idx,:);
end
end

% ---------------------------------------------------------------------------
function v = peak2peak(data, chans)
% Largest peak-to-peak swing (max minus min) of any of these channels, per
% trial. The eye channels are left out: they would trip on every blink.
[~, idx] = ismember(chans, data.label);
idx = idx(idx > 0);
v = zeros(numel(data.trial), 1);
for t = 1:numel(data.trial)
    x = data.trial{t}(idx,:);
    v(t) = max(max(x,[],2) - min(x,[],2));
end
end

% ---------------------------------------------------------------------------
function q = pct(x, p)
% Percentiles without the Statistics Toolbox, the same convention as prctile.
x = sort(x(:)); n = numel(x);
if n < 2, q = repmat(x, size(p)); return; end
q = interp1((0.5:n-0.5)/n, x, p/100, 'linear', 'extrap');
q = min(max(q, x(1)), x(end));
end

% ---------------------------------------------------------------------------
function x = getchan(data, name)
i = find(strcmp(data.label, name), 1);
if isempty(i), error('Channel %s not found.', name); end
x = data.trial{1}(i,:);
end

% ---------------------------------------------------------------------------
function restoreft(before)
global ft_default %#ok<GVMIS>
ft_default = before;
end
