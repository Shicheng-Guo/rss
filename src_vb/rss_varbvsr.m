function [lnZ, alpha, mu, s, info] = rss_varbvsr(betahat, se, SiRiS, sigb, logodds, options)
% USAGE: mean-field variational inference of RSS-BVSR model for a given set of hyperparameters
% INPUT:
%       betahat: effect size estimates under single-SNP model, p by 1
%       se: standard errors of betahat, p by 1
%       SiRiS: inv(S)*R*inv(S), double precision sparse matrix (CCS format), p by p
%       sigb: prior SDs of regression coefficients (if included), p by 1 or scalar
%       logodds: log(prior PIP/(1-prior PIP)) of inclusion for each SNP, p by 1 or scalar
%       options: user-specified behaviour of the algorithm, structure
%               - max_walltime: scalar, the maximum wall time (unit: seconds) for this program
%               - tolerance: scalar, convergence tolerance
%               - alpha & mu: p by 1 vectors, initial values of variational parameters
%               - verbose: logical, print program progress if true
%               - elbo_tol: scalar, stop iteration when ELBO increase is below this value
% OUTPUT:
%	lnZ: scalar, variational lower bound of the marginal log likelihood (up to some constant)
%	alpha: p by 1, variational estimates of the posterior inclusion probabilities 
%	mu: p by 1, posterior means of the additive effects (if the SNP is included)
%	s: p by 1, posterior variances of the additive effects (if the SNP is included)
%	info: structure with following fields 
%		- iter: integer, number of iterations till convergence
%       	- maxerr: maximum relative difference between the parameters at the last 2 iterations
%		- loglik: iter by 1, variational lower bound at each iteration
%		- exe_time: scalar, total execution time in seconds

  % Get the time when the program starts.
  start_time = clock;

  if ~exist('options', 'var')
    options = [];
  end

  % Set the maximum wall time for this program (unit: seconds).
  if isfield(options,'max_walltime')
    max_walltime = double(options.max_walltime);
  else
    max_walltime = (1*24+11)*3600; % 1 day 11 hours
  end
  fprintf('Wall time limit of this program: %0.2e seconds\n',max_walltime);

  % Set tolerance for convergence, which is reached when the maximum relative distance
  % between successive updates of the variational parameters is less than this quantity.
  if isfield(options,'tolerance')
    tolerance = double(options.tolerance);
  else
    tolerance = 1e-4;
  end
  fprintf('Tolerance for convergence in this program: %0.2e\n',tolerance);

  % Optional: stop the variational updates when
  % the increase in lower bound (ELBO) is small.
  if isfield(options,'elbo_tol')
    elbo_tol = double(options.elbo_tol);
  else
    elbo_tol = NaN;
  end 
  
  % Get the number of variables (p).
  p = length(betahat);

  % Set the hyper-parameters (sigb and logodds).
  if isscalar(sigb)
    disp('Prior SDs (sigb) of all SNPs are the same.');
    sigb = repmat(sigb,p,1);
  end
  if isscalar(logodds)
    disp('Prior log-odds (logodds) of all SNPs are the same.');
    logodds = repmat(logodds,p,1);
  end

  % SiRiS must be a sparse matrix.
  if ~issparse(SiRiS)
    SiRiS = sparse(double(SiRiS));
  end
  
  % Set initial estimates of variational parameters.
  if isfield(options,'alpha')
    alpha = double(options.alpha(:));
  else
    alpha = rand(p,1);
    alpha = alpha / sum(alpha);
  end
  if isfield(options,'mu')
    mu = double(options.mu(:));
  else
    mu = randn(p,1);
  end
  if length(alpha) ~= p || length(mu) ~= p
    error('options.alpha and options.mu must be vectors of the same length');
  end

  % Determine whether to display the algorithm's progress.
  if isfield(options,'verbose')
    verbose = options.verbose;
  else
    verbose = true;
  end

  clear options;
  
  % Compute a few useful quantities for the main loop.
  SiRiSr = full(SiRiS * (alpha .* mu));
  q      = betahat ./ (se .^2);

  % Calculate the variance of the coefficients.
  se_square 	= se .* se;
  sigb_square 	= sigb .* sigb;
  s 		= (se_square .* sigb_square) ./ (se_square + sigb_square);

  % Initialize the fields of the structure info.
  iter   = 0;
  loglik = [];

  % Calculate the variational lower bound based on the initial values.
  r   = alpha .* mu;
  lnZ = q'*r - 0.5*r'*SiRiSr - 0.5*(1./se_square)'*betavar(alpha, mu, s);
  lnZ = lnZ + intgamma(logodds, alpha) + intklbeta_rssbvsr(alpha, mu, s, sigb_square);
  fprintf('Initial log variational lower bound: %13.6e\n',lnZ);
  
  loglik = [loglik; lnZ]; 

  if verbose
    fprintf('       variational    max. incl max.\n');
    fprintf('iter   lower bound  change vars E[b]\n');
  end

  % Repeat until convergence criterion is met.
  while true

    % Go to the next iteration.
    iter = iter + 1;
    
    % Save the current variational parameters and lower bound.
    alpha0  = alpha;
    mu0     = mu;
    lnZ0    = lnZ;
    params0 = [alpha; alpha .* mu];

    % Run a forward or backward pass of the coordinate ascent updates.
    if mod(iter,2)
      I = (1:p);
    else
      I = (p:-1:1);
    end
    [alpha, mu, SiRiSr] = rss_varbvsr_update(SiRiS, sigb, logodds, betahat, se, alpha, mu, SiRiSr, I);

    % Compute the lower bound to the marginal log-likelihood.
    r   = alpha .* mu;
    lnZ = q'*r - 0.5*r'*SiRiSr - 0.5*(1./se_square)'*betavar(alpha, mu, s);
    lnZ = lnZ + intgamma(logodds, alpha) + intklbeta_rssbvsr(alpha, mu, s, sigb_square);

    % Record the variational lower bound at each iteration.
    loglik = [loglik; lnZ]; %#ok<AGROW>

    % Obtain time elapsed between the first and current iterations.
    exe_time = etime(clock, start_time);

    % Print the status of the algorithm and check the convergence criterion.
    % Convergence is reached when the maximum relative difference between
    % the parameters at two successive iterations is less than the specified
    % tolerance, or when the variational lower bound has decreased. I ignore
    % parameters that are very small.
    params = [alpha; r];
    I      = find(abs(params) > 1e-6);
    err    = relerr(params(I),params0(I));
    maxerr = max(err);

    if verbose
      status = sprintf('%4d %+13.6e %0.1e %4d %0.2f',...
                       iter,lnZ,maxerr,round(sum(alpha)),max(abs(r)));
      fprintf(status);
      fprintf(repmat('\b',1,length(status)));
    end

    % Terminate the for loop if ELBO decreases.
    if lnZ < lnZ0

      fprintf('\nWarning: log variational lower bound decreased by %0.2e\n',lnZ0-lnZ);
      alpha = alpha0;
      mu    = mu0;
      lnZ   = lnZ0;
      break

    % Terminate the for loop if variational parameters converge.
    elseif maxerr < tolerance

      fprintf('\nConverged: maximum relative error %0.2e\n',maxerr);
      fprintf('Log variational lower bound of the last step increased by %0.2e\n',lnZ-lnZ0);
      break

    end

    % Optional: terminate the for loop if ELBO increases by a small value.
    elbo_change = lnZ - lnZ0;
    if ~isnan(elbo_tol) && elbo_change <= elbo_tol

      fprintf('\nConverged: log variational lower bound increased by %0.2e\n',lnZ-lnZ0);
      break

    end

    % Terminate the for loop after the given maximum wall time.
    if exe_time >= max_walltime

      fprintf('\nMaximum wall time reached: %0.2e seconds\n',exe_time);
      fprintf('Log variational lower bound of the last step increased by %0.2e\n',lnZ-lnZ0);
      break

    end

  end

  % Show final variational lower bound. 
  fprintf('Final log variational lower bound: %13.6e\n',lnZ);

  % Show total execution time in seconds.
  if exe_time < max_walltime
    fprintf('Total execution time: %0.2e seconds\n',exe_time);
  end

  % Save info as a structure array.
  info = struct('iter',iter,'maxerr',maxerr,'loglik',loglik,'exe_time',exe_time);
  
end
