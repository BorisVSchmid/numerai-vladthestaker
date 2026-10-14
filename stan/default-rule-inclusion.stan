// Advisory inclusion diagnostic, not an allocation or weight-learning model.
// include_model is exactly I(raw D60+|W9(t) > 0); y is standardized D60(t).
// Positive accuracy is P(D60 > 0 | include_model = 1), not overall sign accuracy.
functions {
  real temporal_lpdf(matrix z, array[] int gap, real phi, real persistent) {
    int T = rows(z);
    int D = cols(z);
    vector[D] state = rep_vector(0, D);
    real variance = persistent;
    real lp = 0;
    for (n in 1:T) {
      real S = variance + 1 - persistent;
      real gain = variance / S;
      vector[D] innovation = z[n]' - state;
      lp += normal_lpdf(innovation | 0, sqrt(S));
      state += gain * innovation;
      variance *= 1 - gain;
      if (n < T) {
        real a = pow(phi, gap[n+1]);
        state *= a;
        variance = square(a) * variance + persistent * (1-square(a));
      }
    }
    return lp;
  }
}
data {
  int<lower=2> N;
  int<lower=1> M;
  // Active model histories are nested after sorting by first observed pair.
  int<lower=1, upper=M> G;
  array[G] int<lower=1, upper=M> group_first;
  array[G] int<lower=1, upper=M> group_last;
  array[G] int<lower=1, upper=N> group_start;
  array[N] int<lower=0> gap;
  array[N, M] int<lower=0, upper=1> include_model;
  vector<lower=0, upper=1>[M] positive_fraction;
  matrix[N, M] y;
  vector[M] y_center;
  vector<lower=0>[M] y_scale;
  int<lower=0, upper=1> pooling;
  int<lower=0> H;
  array[H] int<lower=1, upper=N> missing_row;
  array[H] int<lower=1, upper=M> missing_model;
}
transformed data {
  matrix[N,M] centered_include;
  for (m in 1:M) for (n in 1:N)
    centered_include[n,m] = include_model[n,m] - positive_fraction[m];
}
parameters {
  vector[M] alpha;
  real beta_mean;
  real<lower=0> beta_sd;
  vector[M] beta_raw;
  vector<lower=0>[M] sigma;
  cholesky_factor_corr[M] L_Omega;
  real<lower=0, upper=1> phi;
  real<lower=0, upper=1> persistent;
  // Missing standardized residuals are integrated under the same joint
  // Gaussian law. Missing predictors cannot affect the observed likelihood.
  vector[H] missing_residual;
}
transformed parameters {
  // beta is the positive-minus-nonpositive D60 mean difference in D60 SDs.
  vector[M] beta;
  if (pooling == 1) beta = beta_mean + beta_sd * beta_raw;
  else beta = 0.5 * beta_raw;
}
model {
  matrix[M, M] L = diag_pre_multiply(sigma, L_Omega);
  matrix[N, M] residual = y - rep_matrix(alpha',N)
    - rep_matrix(beta',N) .* centered_include;
  matrix[M, N] z;
  for (h in 1:H)
    residual[missing_row[h],missing_model[h]] = missing_residual[h];
  // For an observed prefix, its spatial whitening uses only that prefix.
  // Entries preceding a model's start are never included in its likelihood.
  z = mdivide_left_tri_low(L, residual');
  alpha ~ normal(0, 1);
  beta_mean ~ normal(0, 0.5);
  beta_sd ~ normal(0, 0.5);
  beta_raw ~ std_normal();
  sigma ~ lognormal(-0.2, 0.7);
  L_Omega ~ lkj_corr_cholesky(4);
  phi ~ beta(2, 1);
  persistent ~ beta(2, 2);
  for (g in 1:G) {
    int a = group_first[g];
    int b = group_last[g];
    int s = group_start[g];
    target += temporal_lpdf(z[a:b,s:N]' | gap[s:N], phi, persistent);
    target += -(N-s+1) * sum(log(diagonal(L[a:b,a:b])));
  }
}
generated quantities {
  vector[M] mean_d60_positive;
  vector[M] mean_d60_nonpositive;
  vector[M] mean_difference;
  vector[M] prob_d60_positive_given_positive;
  vector[M] prob_d60_positive_given_nonpositive;
  vector<lower=0, upper=1>[M] positive_accuracy;
  vector<lower=0, upper=1>[M] overall_positive_rate;
  for (m in 1:M) {
    real mu_pos = alpha[m] + beta[m] * (1-positive_fraction[m]);
    real mu_nonpos = alpha[m] - beta[m] * positive_fraction[m];
    mean_d60_positive[m] = y_center[m] + y_scale[m]*mu_pos;
    mean_d60_nonpositive[m] = y_center[m] + y_scale[m]*mu_nonpos;
    mean_difference[m] = y_scale[m]*beta[m];
    prob_d60_positive_given_positive[m] = Phi(mean_d60_positive[m]/(y_scale[m]*sigma[m]));
    prob_d60_positive_given_nonpositive[m] = Phi(mean_d60_nonpositive[m]/(y_scale[m]*sigma[m]));
    positive_accuracy[m] = prob_d60_positive_given_positive[m];
    overall_positive_rate[m] = positive_fraction[m] * positive_accuracy[m]
      + (1-positive_fraction[m]) * prob_d60_positive_given_nonpositive[m];
  }
}
