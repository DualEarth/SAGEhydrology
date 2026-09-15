function [loss,delta] = delta_sm(Sm,sm)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%DELTA_SM Soil-moisture loss and its sensitivity vector dL/dSm
%
% Companion to delta_n for the soil-moisture objective. delta_n returns
% dL/dq for discharge; this returns dL/dSm, so that crr_model can form
% g = J'*delta + lambda*(J_Sm'*delta_sm).
%
%       L = mean_t ( z_S(t) - z_O(t) )^2
%       z_S = (Sm - mean(Sm))/std(Sm),  z_O = (y - mu_obs)/sd_obs
%
% Standardising is what makes the comparison legal: Sm is a conceptual
% storage in mm, while remotely sensed soil moisture is volumetric water
% content in m3/m3, so only the anomalies are comparable.
%
% SYNOPSIS: [loss,delta] = delta_sm(Sm,sm)
%   Sm          nx1 simulated soil moisture (mm), on the training mask
%   sm          structure with soil-moisture target information
%    .y          nx1 observed soil moisture on the same mask
%    .mu_obs     scalar reference mean of the observed series
%    .sd_obs     scalar reference stdev of the observed series
%   loss        OUTPUT: scalar mean squared z-score difference
%   delta       OUTPUT: nx1 loss-sensitivity vector dL/dSm
%
% NOTES:
%   The simulated series is standardised by its own mean and stdev,
%   recomputed on every call. Both are therefore functions of theta, so
%   every timestep couples to every other and delta picks up two correction
%   terms, in the same way delta_n case 4 propagates dm_q/dq and ds_q/dq for
%   KGE.
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    n = numel(Sm);
    if n == 0
        loss = NaN; delta = zeros(0,1); return
    end

    mu = mean(Sm); sd = std(Sm);                % recomputed every call

    % A zero or non-finite scale on either side leaves the z-scores
    % undefined. Return a non-finite loss AND a zero delta together, so a
    % caller that skips the loss cannot silently still add a NaN gradient.
    if ~(sd > 0) || ~isfinite(sd) ...
            || ~isfield(sm,'sd_obs') || ~(sm.sd_obs > 0) ...
            || ~isfinite(sm.sd_obs) || ~isfinite(sm.mu_obs)
        loss = NaN; delta = zeros(n,1); return
    end

    z_S = (Sm(:)   - mu)/sd;                    % standardised simulated
    z_O = (sm.y(:) - sm.mu_obs)/sm.sd_obs;      % standardised observed

    e_n = z_S - z_O;                            % n x 1 vector of residuals

    loss = mean(e_n.^2);

    % mu and sd depend on Sm: dmu/dSm_u = 1/n and dsd/dSm_u = z_u/(n-1)
    A = sum(e_n);
    B = sum(e_n.*z_S);
    delta = (2/(n*sd)) * ...
        (e_n - A/n - B*z_S/(n-1));            

end
