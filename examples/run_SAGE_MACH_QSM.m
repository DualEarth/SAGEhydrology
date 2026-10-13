% ========================================================================
%   S A G E   -   MACH-US, discharge + SMAP soil moisture, CFE-NWM
% ========================================================================
%
% Joint Q + SM counterpart of run_SAGE_MACH_Q.m. Same pipeline as the
% exported project scripts (projects/P05_multivariable_MACH), with:
%   Region         : MACH-US daily, 671 basins with SMAP (training 531,
%                    eval 140)
%   Model          : CFE-NWM
%   Training       : 01 Oct 2016 - 30 Sep 2020
%   Evaluation     : 01 Oct 2020 - 30 Sep 2023
%   Loss           : discharge + SMAP L4 root-zone soil moisture,
%                    equal normalized weights (as in project 05)
% The periods lie inside the SMAP L4 record (from 31 Mar 2015), so this
% run is directly comparable to the discharge-only baseline.
%
% Data: <root>/Data/MACH_US (daily/timeseries, attributes,
% MACH_basins_all.gpkg), where <root> is the folder holding SAGEhydrology.
%
% HOW TO RUN
%   1. MACH-US (Sink and Brikowski, 2026; https://zenodo.org/records/18686475):
%      download MACH_ts.zip, attributes.zip and MACH_basins_all.gpkg, and
%      arrange them as
%        <root>/Data/MACH_US/daily/timeseries/basin_<gauge>_MACH.csv
%        <root>/Data/MACH_US/attributes/site_info.csv, ...
%        <root>/Data/MACH_US/MACH_basins_all.gpkg
%   2. SMAP L4 (SPL4SMGP): extract the 3-hourly root-zone and surface soil
%      moisture at each gauge, average to daily means, and save a CSV with
%      columns gauge, Date, l4_root, l4_surf (m3/m3). Then write one file
%      per basin:
%        python utils/smap/build_mach_smap.py smap_daily.csv ...
%            regions/US/MACH/MACH_1014_basins.txt <root>/Data/MACH_US
%      This creates daily/timeseries/smap/smap_<gauge>.csv, which
%      region_config_MACH.m reads as SM (l4_root x 1000 = mm over 0-100 cm).
%      Every MACH basin needs a file, also for discharge-only runs.
%   3. In MATLAB, from the SAGEhydrology folder:
%        run('examples/run_SAGE_MACH_Q.m')     % discharge-only baseline
%        run('examples/run_SAGE_MACH_QSM.m')   % discharge + soil moisture
%      Results go to results/MACH671_Q_cfe and results/MACH671_QSM_cfe.

clear
clc

wallTimerTotal = tic; wallTData = 0;
%% Installation and data paths
SAGEhydro = fileparts(fileparts(mfilename('fullpath')));
root = fileparts(SAGEhydro);
SAGEdir = SAGEhydro;
region = 'MACH_US';
regionName = 'United States (MACH)';
% 671 MACH basins with SMAP L4 data (MACH's own train/eval assignment;
% use MACH_1014_basins.txt, split_MACH_1014_800_214_1.txt, 1014/800/214
% for all basins)
file_univ = 'MACH_671_basins.txt';
file_split = 'split_MACH_671_531_140_1.txt';
dirDroot = fullfile(root,'Data');
dirD = fullfile(dirDroot,'MACH_US');
dirM = fullfile(dirD,'daily','timeseries');
dirQ = fullfile(dirD,'daily','timeseries');
dirres = fullfile(SAGEhydro,'results','MACH671_QSM_cfe');

%% Model configuration
mdl.model = 7;              % CFE-NWM
mdl.mcode = 4;
mdl.calc = 'parfeval';
mdl.mode = 4;
% Model names indexed by mdl.model (normally supplied by the GUI; used by
% print_SAGE, postproc_SAGE and plot_SAGE). Codes as in sage_model_name.
mdl.names = {'hymod','hmodel','sacsma','Xinanjiang','gr4jA','hbv', ...
    'cfe_nwm'};

%% Basin selection and attributes
bas.K = 671;
bas.K_t = 531;
bas.K_e = 140;
bas.sample = 'file';
bas.pr_attr = 0;
bas.dt = 1;
bas.mode = 4;

%% Training and evaluation periods
prd.dt = 1;
prd.method = 'manual';
prd.dts = [1 10 2016];
prd.dte = [30 9 2020];
prd.des = [1 10 2020];
prd.dee = [30 9 2023];
prd.spinup = 365;
prd.eval_was_empty = false;
prd.eval_partial = false;

%% Feedforward neural-network settings
net.h = 32;
net.tf = {'tanh'};
net.seed = 0;

%% Loss-function settings
loss.fnc = 2;
loss.method = 1;
loss.n_win = 7;
loss.M = 2;
loss.observed = {'Q', 'SM'};
loss.weight.Q = 1/2;
loss.weight.SM = 1/2;
loss.normalization.method = 'auto';

%% Optimization settings
alg.method = 2;
alg.i_max = 250;
alg.lr = 0.01;
alg.beta_1 = 0.9;
alg.beta_2 = 0.999;
alg.vareps = 1e-8;
alg.wdecay = 1e-4;
alg.clipn = 1;
alg.lr_min = 1e-4;
alg.lr_scheme = 'constant';
alg.lr_hold = 0.2;

%% Numerical solver settings
ode.InitStep = 0.01;
ode.MaxStep = 1;
ode.MinStep = 1e-4;
ode.RelTol = 1e-3;
ode.AbsTol = 1e-3;
ode.Order = 2;
ode.maxiter = 10000;
ode.mem = 0;

%% Miscellaneous forcing, output, and plotting settings
misc.meteo.data = 1;
misc.meteo.precip = 1;
misc.meteo.temp = 1;
misc.meteo.pet = 1;
misc.io.prt = 1;
misc.io.file = 1;
misc.attr = 0;
misc.attr_view = 'abs';
misc.plot.Btr = 5;
misc.plot.Bev = 5;
misc.plot.gaugescen.tt = {};
misc.plot.gaugescen.te = {};
misc.plot.gaugescen.et = {};
misc.plot.gaugescen.ee = {};
misc.crr_backend = 'cpp';

parOverride = struct();

%% Initialize SAGEhydrology
% bootstrap_SAGE only recognises a repository that has the gui/ folder,
% which the public source does not ship, so do its steps here: add the
% code trees to the path, resolve the region and create the results folder.
for sub = {'src','utils','models','regions'}
    addpath(genpath(fullfile(SAGEhydro,sub{1})));
end
region = region_helpers('code',region);
if ~isfolder(dirres), mkdir(dirres); end
mdl.region = region;
clear sub
% MACH default attributes (excludes discharge-derived signatures)
ATTR = attr_catalog('MACH_US');
bas.id_attr = ATTR.default_ids(:).';

%% Prepare data and hydrologic model
write_header(mdl,'sage',{'Run','MACH-US discharge + SMAP soil moisture (CFE-NWM)'})
ode = read_numsettings(ode);
wallTimerData = tic;
[A_reg,ID,gname,zone] = read_attr(region,dirD,bas);
wallTData = wallTData + toc(wallTimerData);
[A,bas,latlon] = sample_basins(A_reg,ID,bas,prd, ...
    gname,zone,dirD,file_univ,file_split);
[mdl,misc,crrStatus] = crr_prepare_backend(mdl,misc);
mdl.crr_backend = misc.crr_backend;
fprintf('... Preparing CRR backend ... Done\n');
fprintf('      %s.\n',crrStatus);
[mdl,d] = read_model(mdl,prd);
mdl = apply_parameter_override( ...
    mdl,parOverride,mdl.model,prd.dt);
net.r = size(A,1); net.d = d;
[split,mdl] = build_split(mdl,prd,bas);
wallTimerData = tic;
[dat,aux] = read_meteo(region,dirM,bas,split,misc.meteo);
wallTData = wallTData + toc(wallTimerData);
wallTimerData = tic;
dat = read_Q(region,dirQ,mdl,dat,bas,split,aux);
wallTData = wallTData + toc(wallTimerData);
[eligibility,dat] = check_basins(dat,mdl,bas);
[dat,A,latlon,bas] = filter_basins(dat,A,latlon,bas,eligibility);
[dat,loss] = prep_stats(dat,mdl,split,loss);
setup_parpool(mdl,bas);
[prf,ax,tTheta,At,An,nTheta] = init_args(bas,mdl,alg,misc.attr);
prf.wallT_data = wallTData;
prf.wallT_init = max(0,toc(wallTimerTotal)-wallTData);

%% Train neural network
for i = 1:alg.i_max
    T = tic;
    if i == 1
        [phi,net] = ffn_theta('init',net);
        opts = descent('init',alg,phi);
    else
        [phi,opts] = descent('dyn',alg,phi,dLdphi,i,opts);
        prf.iter.lr(i) = opts.lr_current;
    end
    [nTheta,cache] = ffn_theta('eval',phi,A);
    [L,G,met,At(:,:,i),An(:,:,i),Qfdc,loss] = ...
        camels(nTheta,mdl,dat,bas,ode,loss,misc,d,i,dirres);
    prf = pmetrics(bas,loss,L,met,i,prf);
    tTheta = trace_theta(tTheta,nTheta,bas,i);
    if i < alg.i_max
        dLdphi = ffn_theta('back',phi,cache,alg,G);
    end
    prf.iter.cpuT(i) = toc(T);
    ax = print_SAGE(mdl,ax,prf,i,dirres,loss,net);
end
prf.wallT_train = sum(prf.iter.cpuT,'omitnan');
prf.wallT_info = 0; prf.wallT_gui = 0;

%% Postprocessing and export
wallTimerPost = tic;
Q = postproc_SAGE('sage',nTheta,mdl, ...
    dat,bas,prd,ode,loss,dirres,met);
plot_SAGE('sage',mdl,dat,bas,prd,Q,prf.curr, ...
    Qfdc,region,tTheta,latlon,nTheta, ...
    At,An,misc.plot.gaugescen);
export_SAGE(mdl,dat,bas,prd,dirres, ...
    Q,prf,region,nTheta);
prf.wallT_post = toc(wallTimerPost);
prf.wallT_total = toc(wallTimerTotal);
save(fullfile(dirres,'run_MACH_QSM.mat'),'phi','net','nTheta','prf', ...
    'mdl','bas','prd','loss','alg','ode','misc','-v7.3');
fprintf('\nDone. Results in %s\n',dirres);
