function run_SAGE_smap(LAMBDA,IMAX)
%RUN_SAGE_SMAP  Train CFE-NWM with SAGE using a SMAP L4 soil-moisture objective.
%
% Same pipeline as demo_SAGE, with a soil-moisture term added to the loss:
%
%   L = L_discharge + LAMBDA * mean_t ( z(Sm) - z(L4) )^2
%
% where Sm is the CFE-NWM soil storage and L4 is SMAP L4 soil moisture,
% both standardised. LAMBDA = 0 skips the term and gives a discharge-only
% run. The differences from demo_SAGE are:
%   - loss.lambda sets the weight on the soil-moisture term
%   - the MATLAB backend is used, since the unified C++ backend has no
%     soil-moisture term
%   - prep_smap builds the SMAP target for the chosen basins and periods,
%     and attach_smap adds it to dat
%   - basins and periods are set below instead of through the GUI helpers
%
% HOW TO RUN
%   1. Forcing and streamflow. CAMELS-US style daily files under dirD:
%        daily/v1p2/forcing/nldas/<huc>/<gauge>_lump_nldas_forcing_leap.txt
%        daily/v1p2/streamflow/<huc>/<gauge>_streamflow_qc.txt
%      covering the spin-up and the training and evaluation periods. SMAP
%      L4 starts on 31 March 2015 and the standard CAMELS-US files end in
%      2014, so they have to be extended past 2014 first.
%   2. SMAP L4. Extract SPL4SMGP at each gauge (for example with AppEEARS),
%      average the 3-hourly values to daily means and save a CSV with the
%      columns gauge, Date, l4_root and l4_surf (m3/m3). Set fcsv to it.
%   3. Basins. Put a basin list and a training/evaluation split in
%      regions/US, in the format of US_100_basins.txt and
%      split_US_100_75_25_1.txt, and set file_univ, file_split, K, K_t and
%      K_e to match.
%   4. Periods. Set prd so that the training and evaluation periods lie
%      inside the SMAP record and the forcing covers the spin-up before them.
%   5. Run, for example
%        run_SAGE_smap(0,600)     % discharge only
%        run_SAGE_smap(1,600)     % with the soil-moisture term
%      Each run writes results/<runname>_lam<LAMBDA>_i<IMAX>/ with run.mat
%      (trained network, parameters and settings) and the SMAP target used.
%
% The settings below are the 100-basin CAMELS-US experiment.

if nargin < 1, LAMBDA = 0;   end
if nargin < 2, IMAX   = 600; end

root = fileparts(fileparts(mfilename('fullpath')));
addpath(genpath(root),'-begin');

% ------------------------------------------------------------ settings
dirD       = 'D:\SAGE_Data_NLDAS_100\CAMELS_US';               % CAMELS-US data
fcsv       = fullfile(root,'Data','SMAP','smap_daily_100.csv'); % daily SMAP L4
smvar      = 'l4_root';                                        % or 'l4_surf'
file_univ  = 'US_100_basins.txt';                              % in regions/US
file_split = 'split_US_100_75_25_1.txt';
K = 100; K_t = 75; K_e = 25;                                   % match the files
prd = struct('dt',1,'method','manual','spinup',5*365, ...
    'dts',[1 1 2016],'dte',[31 12 2017], ...                  % training period
    'des',[1 1 2018],'dee',[31 12 2018]);                     % evaluation period
runname    = 'US100_sm';

assert(isfolder(dirD), ...
    'CAMELS-US data not found at %s; set dirD in run_SAGE_smap',dirD);
assert(isfile(fcsv), ...
    'SMAP L4 CSV not found at %s; set fcsv in run_SAGE_smap',fcsv);

dirres = fullfile(root,'results',sprintf('%s_lam%s_i%d',runname, ...
    strrep(sprintf('%g',LAMBDA),'.','p'),IMAX));
if ~isfolder(dirres), mkdir(dirres); end
fsm = fullfile(dirres,'smap_target.mat');

fprintf('\n=== run_SAGE_smap ===\n');
fprintf('  lambda  : %g   i_max: %d\n',LAMBDA,IMAX);
fprintf('  results : %s\n\n',dirres);

region = 'CAMELS_US';
dirM = fullfile(dirD,'daily','v1p2','forcing');
dirQ = fullfile(dirD,'daily','v1p2','streamflow');

% mdl.names is normally supplied by the GUI; compile_model indexes it by
% mdl.model, so it must follow read_model's numbering.
mdl = struct('model',7,'mcode',4,'calc','seq','mode',4, ...
    'names',{{'hymod','hmodel','sacsma','xinanjiang','gr4jA','hbv', ...
              'cfe_nwm','gr4jB'}});
ATTR = attr_catalog(region);
bas = struct('K',K,'K_t',K_t,'K_e',K_e,'sample','file','mode',4, ...
    'id_attr',ATTR.default_ids(:).','pr_attr',0);
bas.r = numel(bas.id_attr);

loss = struct('fnc',3,'n_win',31,'method',1,'M',2,'lambda',LAMBDA);
net  = struct('h',32,'tf','tanh');
alg  = struct('method',2,'i_max',IMAX,'clipn',1,'wdecay',1e-4,'lr',1e-2);
ode  = struct('InitStep',0.01,'MaxStep',1,'MinStep',1e-4, ...
    'RelTol',1e-3,'AbsTol',1e-3,'Order',2,'maxiter',10000,'mem',0);
misc = struct('meteo',struct('data',3,'pet',1,'temp',1), ...
    'io',struct('file',1),'plot',struct('gaugescen',[]),'attr',0);

% ---------------------------------------------------------- initialise
% bootstrap_SAGE needs the gui/ folder, which is not in the repository.
region = region_helpers('code',region);
ode = read_numsettings(ode);
[A_reg,ID,gname,zone] = read_attr(region,dirD,bas);
[A,bas,latlon] = sample_basins(A_reg,ID,bas,prd,gname,zone, ...
    dirD,file_univ,file_split);                                 %#ok<ASGLU>
[mdl,misc] = prepare_crr_backend(mdl,misc);
% prepare_crr_backend picks the unified C++ backend, which has no
% soil-moisture term, so switch to crr_model.m and the cfe_nwm MEX.
misc.crr_backend = 'matlab'; mdl.crr_backend = 'matlab';
assert(compile_model(mdl) >= 0,'the standalone cfe_nwm MEX is unavailable');
[mdl,d] = read_model(mdl,prd);
net.r = size(A,1); net.d = d;
[split,mdl] = build_split(mdl,prd,bas);

% Built from this run's basins and split, so the target always matches.
prep_smap('Csv',fcsv,'File',fsm,'Var',smvar, ...
    'Bas',bas,'Split',split,'Mdl',mdl);

[dat,aux] = read_meteo(region,dirM,bas,split,misc.meteo);
dat = read_Q(region,dirQ,mdl,dat,bas,split,aux);
check_basins(dat,mdl,bas);
[dat,loss] = prep_stats(dat,mdl,split,loss);
dat = attach_smap(dat,bas,'File',fsm);

[prf,ax,tTheta,At,An,nTheta] = init_args(bas,mdl,alg,misc.attr);

% ------------------------------------------------------------- train
for i = 1:alg.i_max
    T = tic;
    if i == 1
        [phi,opts] = descent('init',alg,net);
        net.l = opts.n_phi;
    else
        [phi,opts] = descent('dyn',alg,phi,dLdphi,i,opts);
        prf.iter.lr(i) = opts.lr_current;
    end
    nTheta = ffn_theta('eval',phi,A);
    [L,G,met,At(:,:,i),An(:,:,i),Qfdc] = ...
        camels(nTheta,mdl,dat,bas,ode,loss,misc,d,i,dirres);   %#ok<ASGLU>
    prf = pmetrics(bas,loss,L,met,i,prf);
    tTheta = trace_theta(tTheta,nTheta,bas,i);
    if i < alg.i_max
        dLdphi = ffn_theta('grad',phi,A(:,1:bas.K_t),alg,G);
    end
    prf.iter.cpuT(i) = toc(T);
    ax = print_SAGE(mdl,ax,prf,i,dirres,loss,net);
end

% -------------------------------------------------------------- save
nTh_final = nTheta;
Th_final = mdl.th_min(:) + nTh_final .* (mdl.th_max(:) - mdl.th_min(:));
% C carries the reader arguments so post-processing can rebuild dat.
C = struct('region',region,'dirD',dirD,'dirM',dirM,'dirQ',dirQ, ...
    'prd',prd,'misc',misc,'ode',ode,'root',root,'fsm',fsm);
save(fullfile(dirres,'run.mat'),'phi','prf','tTheta','nTh_final', ...
    'Th_final','mdl','split','bas','A','loss','alg','net','ode','C', ...
    'LAMBDA','IMAX','-v7.3');
fprintf('\nDone. Results in %s\n',dirres);
end
