function transform = loss_transform(loss,name)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%LOSS_TRANSFORM Return the selected loss transform of a named observation.
%
%  Reads loss.transform.<name>. 'none' (default) scores the observation
%  with loss.fnc on its original scale. 'zscore' standardizes simulation
%  and observation over the valid days of the scored period and replaces
%  loss.fnc for that observation by mean((z_sim - z_obs).^2) = 2(1 - r),
%  so that only the timing (correlation) is fitted, not level or spread.
%
% SYNOPSIS:
%   transform = loss_transform(loss,name)
%
% INPUT ARGUMENTS:
%   loss            loss-function settings
%    .transform      optional structure, e.g. struct('SM','zscore')
%   name            observation name: 'Q', 'SWE', or 'SM'
%
% OUTPUT ARGUMENTS:
%   transform       'none' or 'zscore'
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Written by Kunal Sarna, Oct. 2026                                       %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    transform = 'none';
    if ~isfield(loss,'transform') ...
            || isempty(loss.transform)
        return
    end
    if ~isstruct(loss.transform)
        error('loss_transform:InvalidTransform', ...
            ['loss.transform must be a structure with one field ' ...
             'per observation, e.g. loss.transform.SM = ''zscore''.']);
    end
    unknown = setdiff(fieldnames(loss.transform),{'Q','SWE','SM'});
    if ~isempty(unknown)
        error('loss_transform:UnknownObservation', ...
            'Unknown loss.transform observation(s): %s.', ...
            strjoin(unknown,', '));
    end
    field = char(upper(string(name)));
    if ~isfield(loss.transform,field) ...
            || isempty(loss.transform.(field))
        return
    end
    transform = lower(strtrim(char(string(loss.transform.(field)))));
    if ~ismember(transform,{'none','zscore'})
        error('loss_transform:UnknownTransform', ...
            ['loss.transform.%s must be ''none'' or ''zscore'' ' ...
             '(got ''%s'').'],field,transform);
    end
end
