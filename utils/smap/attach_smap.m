function dat = attach_smap(dat,bas,varargin)
%ATTACH_SMAP  Attach a prepared SMAP soil-moisture target to dat.
%
% Loads the file written by prep_smap and sets dat{k}.sm for each basin,
% matched by gauge id. Call it after prep_stats:
%
%   [dat,loss] = prep_stats(dat,mdl,split,loss);
%   dat = attach_smap(dat,bas,'File',file);
%
% crr_model uses dat{k}.sm only when loss.lambda > 0, so at lambda = 0 the
% target is ignored.
%
% dat{k}.sm fields (built by prep_smap):
%   .y            nx1 observed SMAP L4 soil moisture (m3/m3), model axis
%   .bad          1xn logical, true where no observation
%   .mu_obs       reference mean  of the observations, training window
%   .sd_obs       reference stdev of the observations, training window

% Default to the repository own data folder. Prepared targets are data,
% not source, and Data/ is gitignored for the same reason CAMELS is.
p = inputParser;
p.addParameter('File',fullfile( ...
    fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
    'Data','SMAP','smap_prepared.mat'));
p.addParameter('Verbose',true);
p.parse(varargin{:});
o = p.Results;

L = load(o.File);
sm = L.sm;

% bas.id_gauge may be numeric or a string array; match on the numeric id.
gsrc = local_num(cellfun(@(s) s.gauge,sm,'uni',0));

for k = 1:bas.K
    g = local_num({bas.id_gauge(k)});
    j = find(gsrc == g,1);
    if isempty(j)
        error('attach_smap:missing', ...
            'No prepared soil-moisture target for gauge %d in %s', ...
            g,o.File);
    end
    n = numel(dat{k}.y_n);
    if numel(sm{j}.y) ~= n
        error('attach_smap:length', ...
            ['Gauge %d: target has %d steps but dat{%d}.y_n has %d. ' ...
             'The prepared file was built for a different period -- ' ...
             'rerun prep_smap.'],g,numel(sm{j}.y),k,n);
    end
    dat{k}.sm = sm{j};
end

if o.Verbose
    fprintf('      attach_smap: attached %s target to %d basins\n', ...
        sm{1}.var,bas.K);
end
end

function v = local_num(c)
v = nan(numel(c),1);
for i = 1:numel(c)
    x = c{i};
    if isnumeric(x), v(i) = double(x); else, v(i) = str2double(string(x)); end
end
end
