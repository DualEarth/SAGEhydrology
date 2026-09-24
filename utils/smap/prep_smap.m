function sm = prep_smap(varargin)
%PREP_SMAP  Build the SMAP L4 soil-moisture target for a set of basins.
%
% Reads a daily SMAP L4 table with one row per gauge per day and aligns
% each basin in bas onto the model output axis, which runs from the start
% of the training period to the end of the evaluation period. Days without
% an observation are marked in .bad. The observed mean and stdev are taken
% over the valid training-period days; the simulated statistics are
% recomputed inside delta_sm, so no reference simulation is needed.
%
% The CSV needs a gauge column, a Date column and the SMAP L4 variable to
% use (l4_root or l4_surf, in m3/m3). The result is saved to File and read
% back by attach_smap.
%
% SYNOPSIS:
%   sm = prep_smap('Bas',bas,'Split',split,'Mdl',mdl);
%   sm = prep_smap('Csv',csv,'File',out,'Var','l4_surf', ...
%                  'Bas',bas,'Split',split,'Mdl',mdl);

p = inputParser;
p.addParameter('Csv','');
p.addParameter('Var','l4_root');
p.addParameter('Bas',[]);
p.addParameter('Split',[]);
p.addParameter('Mdl',[]);
p.addParameter('File','');
p.addParameter('Save',true);
p.parse(varargin{:});
o = p.Results;

% SMAP extracts and prepared targets are data, so both default to the
% repository gitignored Data/SMAP folder.
ddir = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
    'Data','SMAP');
if isempty(o.Csv),  o.Csv  = fullfile(ddir,'smap_daily.csv');    end
if isempty(o.File), o.File = fullfile(ddir,'smap_prepared.mat'); end

bas = o.Bas; split = o.Split; mdl = o.Mdl;
assert(~isempty(bas) && ~isempty(split) && ~isempty(mdl), ...
    'prep_smap needs Bas, Split and Mdl');

opts = detectImportOptions(o.Csv);
opts = setvartype(opts,'gauge','string');
T = readtable(o.Csv,opts);
T.Date = datetime(T.Date);
Tg = double(str2double(T.gauge));

axis_t = (split.dt_train0:split.dt_end)';
n = numel(axis_t);
id_tr = expand_index(mdl.id_train);

fprintf('\n=== prep_smap ===\n');
fprintf('  variable    : %s\n',o.Var);
fprintf('  model axis  : %s .. %s   (n = %d)\n\n', ...
    string(axis_t(1)),string(axis_t(end)),n);

sm = cell(bas.K,1);
nmiss = zeros(bas.K,1);
for k = 1:bas.K
    g = str2double(string(bas.id_gauge(k)));    % ids may be numeric or string
    sel = (Tg == g);
    assert(any(sel),'no soil-moisture rows for gauge %d',g);
    Tk = T(sel,:);

    [tf,loc] = ismember(axis_t,Tk.Date);
    y = nan(n,1);
    y(tf) = Tk.(o.Var)(loc(tf));
    bad = ~isfinite(y);
    nmiss(k) = sum(bad);

    v = id_tr(~bad(id_tr));
    sm{k} = struct('gauge',g,'var',o.Var, ...
        'y',y,'bad',bad(:)', ...
        'mu_obs',mean(y(v)),'sd_obs',std(y(v)));
end

allY = cell2mat(cellfun(@(s) s.y,sm,'uni',0));
fprintf('  basins            : %d\n',bas.K);
fprintf('  missing days      : %d of %d (%.2f%%), worst basin %d\n', ...
    sum(nmiss),bas.K*n,100*sum(nmiss)/(bas.K*n),max(nmiss));
fprintf('  observed range    : [%.3f %.3f] m3/m3\n', ...
    min(allY),max(allY));
fprintf('  sd_obs range      : [%.4f %.4f]\n', ...
    min(cellfun(@(s) s.sd_obs,sm)),max(cellfun(@(s) s.sd_obs,sm)));

bad = min(allY) < 0 || max(allY) > 1 ...
    || any(~isfinite(cellfun(@(s) s.sd_obs,sm))) ...
    || any(cellfun(@(s) s.sd_obs,sm) <= 0);
if bad
    fprintf('\n  CHECK -- values out of range or a degenerate sd_obs\n\n');
else
    fprintf('\n  PASS -- aligned, in range, statistics finite\n');
end

if o.Save
    fdir = fileparts(o.File);
    if ~isempty(fdir) && ~isfolder(fdir), mkdir(fdir); end
    save(o.File,'sm','-v7.3');
    fprintf('  saved %s\n\n',o.File);
end
end
