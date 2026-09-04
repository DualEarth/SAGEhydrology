function [loss,delta] = delta_sm(Sm,sm)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%DELTA_SM Soil-moisture loss and its sensitivity vector dL/dSm
%
% Companion to delta_n for the soil-moisture objective. delta_n returns
% dL/dq for discharge; this returns dL/dSm, so that crr_model can form
% g = J'*delta + lambda*(J_Sm'*delta_sm).
%
%       L = mean_t ( z_S(t) - z_O(t) )^2
%       z_S = (Sm - mu_sim)/sd_sim,  z_O = (y - mu_obs)/sd_obs
%
% Standardising is what makes the comparison legal: Sm is a conceptual
% storage in mm, while remotely sensed soil moisture is volumetric water
% content in m3/m3, so only the anomalies are comparable.
%
% SYNOPSIS: [loss,delta] = delta_sm(Sm,sm)
%   Sm          nx1 simulated soil moisture (mm), on the training mask
%   sm          structure with soil-moisture target information
%    .y          nx1 observed soil moisture on the same mask
%    .mu_sim     scalar fixed reference mean of the simulated series
%    .sd_sim     scalar fixed reference stdev of the simulated series
%    .mu_obs     scalar fixed reference mean of the observed series
%    .sd_obs     scalar fixed reference stdev of the observed series
%   loss        OUTPUT: scalar mean squared z-score difference
%   delta       OUTPUT: nx1 loss-sensitivity vector dL/dSm
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    n = numel(Sm);
    if n == 0
        loss = NaN; delta = zeros(0,1); return
    end

    z_S = (Sm(:)   - sm.mu_sim)/sm.sd_sim;      % standardised simulated
    z_O = (sm.y(:) - sm.mu_obs)/sm.sd_obs;      % standardised observed

    e_n = z_S - z_O;                            % n x 1 vector of residuals

    loss = mean(e_n.^2);
    delta = (2/n) * e_n / sm.sd_sim;            % δ(theta)

end
