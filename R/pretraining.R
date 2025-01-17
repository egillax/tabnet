train_batch_un <- function(network, optimizer, batch, config) {
  # forward pass
  output <- network(batch$x, batch$x_na_mask)
  loss <- config$loss_fn(output[[1]], output[[2]], output[[3]])

  # step of the backward pass and optimization
  optimizer$zero_grad()
  loss$backward()
  if (!is.null(config$clip_value)) {
    torch::nn_utils_clip_grad_norm_(network$parameters, config$clip_value)
  }
  optimizer$step()

  list(
    loss = loss$item()
  )
}

valid_batch_un <- function(network, batch, config) {
  # forward pass
  output <- network(batch$x, batch$x_na_mask)
  # we inverse the batch_na_mask here to avoid nan in the loss
  loss <- config$loss_fn(output[[1]], output[[2]], output[[3]]$logical_not())

  list(
    loss = loss$item()
  )
}

transpose_metrics <- function(metrics) {
  nms <- names(metrics[1])
  out <- vector(mode = "list", length = length(nms))
  for (nm in nms) {
    out[[nm]] <- vector("numeric", length = length(metrics))
  }

  for (i in seq_along(metrics)) {
    for (nm in nms) {
      out[[nm]][i] <- metrics[i][[nm]]
    }
  }

  out
}

unsupervised_loss <- function(y_pred, embedded_x, obfuscation_mask, eps = 1e-9) {

  errors <- y_pred - embedded_x
  reconstruction_errors <- torch::torch_mul(errors, obfuscation_mask)^2
  batch_stds <- torch::torch_std(embedded_x, dim=1)^2 + eps

  # compute the number of obfuscated variables to reconstruct
  nb_reconstructed_variables <- torch::torch_sum(obfuscation_mask, dim=2)

  # take the mean of the reconstructed variable errors
  features_loss <- torch::torch_matmul(reconstruction_errors, 1/batch_stds) / (nb_reconstructed_variables + eps)
  loss <- torch::torch_mean(features_loss)
  loss
}

tabnet_train_unsupervised <- function(x, config = tabnet_config(), epoch_shift = 0L) {
  torch::torch_manual_seed(sample.int(1e6, 1))

  if (config$device == "auto") {
    if (torch::cuda_is_available()){
      device <- "cuda"
    } else {
      device <- "cpu"
    }
  } else {
    device <- config$device
  }

  # validation dataset & dataloaders
  has_valid <- config$valid_split > 0
  if (has_valid) {
    n <- nrow(x)
    valid_idx <- sample.int(n, n*config$valid_split)
    valid_x <- x[valid_idx, ]
    valid_ds <-   torch::dataset(
      initialize = function() {},
      .getbatch = function(batch) {resolve_data(valid_x[batch,], rep(1, length(batch)), device=device)},
      .length = function() {nrow(valid_x)}
    )()

    valid_dl <- torch::dataloader(
      valid_ds,
      batch_size = config$batch_size,
      shuffle = FALSE ,
      num_workers = config$num_workers
    )

    x <- x[-valid_idx, ]
  }

  # training dataset & dataloader
  train_ds <-   torch::dataset(
    initialize = function() {},
    .getbatch = function(batch) {resolve_data(x[batch,], rep(1, length(batch)), device=device)},
    .length = function() {nrow(x)}
  )()
  # we can get training_set parameters from the 2 first samples
  train <- train_ds$.getbatch(batch = c(1:2))

  train_dl <- torch::dataloader(
    train_ds,
    batch_size = config$batch_size,
    drop_last = config$drop_last,
    shuffle = TRUE ,
    num_workers = config$num_workers
  )

  # resolve loss (shortcutted from config)
  config$loss_fn <- unsupervised_loss

  # create network
  network <- tabnet_pretrainer(
    input_dim = as.integer(train$input_dim$to(device="cpu")),
    cat_idxs = as.integer(train$cat_idx$to(device="cpu")),
    cat_dims = as.integer(train$cat_dims$to(device="cpu")),
    pretraining_ratio = config$pretraining_ratio,
    n_d = config$n_d,
    n_a = config$n_a,
    n_steps = config$n_steps,
    gamma = config$gamma,
    virtual_batch_size = config$virtual_batch_size,
    cat_emb_dim = config$cat_emb_dim,
    n_independent = config$n_independent,
    n_shared = config$n_shared,
    momentum = config$momentum
  )

  network$to(device = device)

  # define optimizer
  if (rlang::is_function(config$optimizer)) {

    optimizer <- config$optimizer(network$parameters, config$learn_rate)

  } else if (rlang::is_scalar_character(config$optimizer)) {

    if (config$optimizer == "adam")
      optimizer <- torch::optim_adam(network$parameters, lr = config$learn_rate)
    else
      rlang::abort("Currently only the 'adam' optimizer is supported.")

  }

  # define scheduler
  if (is.null(config$lr_scheduler)) {
    scheduler <- list(step = function() {})
  } else if (rlang::is_function(config$lr_scheduler)) {
    scheduler <- config$lr_scheduler(optimizer)
  } else if (config$lr_scheduler == "step") {
    scheduler <- torch::lr_step(optimizer, config$step_size, config$lr_decay)
  }

  # initialize metrics & checkpoints
  metrics <- list()
  checkpoints <- list()
  patience_counter <- 0L

  # main loop
  for (epoch in seq_len(config$epochs) + epoch_shift) {

    metrics[[epoch]] <- list(train = NULL, valid = NULL)
    train_metrics <- c()
    valid_metrics <- c()

    network$train()

    if (config$verbose)
      pb <- progress::progress_bar$new(
        total = length(train_dl),
        format = "[:bar] loss= :loss"
      )

    coro::loop(for (batch in train_dl) {
      m <- train_batch_un(network, optimizer, batch, config)
      if (config$verbose) pb$tick(tokens = m)
      train_metrics <- c(train_metrics, m)
    })
    metrics[[epoch]][["train"]] <- transpose_metrics(train_metrics)

    if (config$checkpoint_epochs > 0 && epoch %% config$checkpoint_epochs == 0) {
      network$to(device = "cpu")
      checkpoints[[length(checkpoints) + 1]] <- model_to_raw(network)
      network$to(device = device)
    }

    network$eval()
    if (has_valid) {
      coro::loop(for (batch in valid_dl) {
        m <- valid_batch_un(network, batch, config)
        valid_metrics <- c(valid_metrics, m)
      })
      metrics[[epoch]][["valid"]] <- transpose_metrics(valid_metrics)
    }

    message <- sprintf("[Epoch %03d] Loss: %3f", epoch, mean(metrics[[epoch]]$train$loss))
    if (has_valid)
      message <- paste0(message, sprintf(" Valid loss: %3f", mean(metrics[[epoch]]$valid$loss)))

    if (config$verbose)
      rlang::inform(message)

    # Early-stopping checks
    if (config$early_stopping && config$early_stopping_monitor=="valid_loss"){
      current_loss <- mean(metrics[[epoch]]$valid$loss)
    } else {
      current_loss <- mean(metrics[[epoch]]$train$loss)
    }
    if (config$early_stopping && epoch > 1+epoch_shift) {
      # compute relative change, and compare to best_metric
      change <- (current_loss - best_metric) / current_loss
      if (change > config$early_stopping_tolerance){
        patience_counter <- patience_counter + 1
        if (patience_counter >= config$early_stopping_patience){
          if (config$verbose)
            rlang::inform(sprintf("Early stopping at epoch %03d", epoch))
          break
        }
      } else {
        # reset the patience counter
        best_metric <- current_loss
        patience_counter <- 0L
      }
    }
    if (config$early_stopping && epoch == 1+epoch_shift) {
      # initialise best_metric
      best_metric <- current_loss
    }


    scheduler$step()
  }

  network$to(device = "cpu")

  importance_sample_size <- config$importance_sample_size
  if (is.null(config$importance_sample_size) && train_ds$.length() > 1e5) {
    rlang::warn(c(glue::glue("Computing importances for a dataset with size {train_ds$.length()}."),
                  "This can consume too much memory. We are going to use a sample of size 1e5",
                  "You can disable this message by using the `importance_sample_size` argument."))
    importance_sample_size <- 1e5
  }
  indexes <- as.numeric(torch::torch_randint(
    1, train_ds$.length(), min(importance_sample_size, train_ds$.length()),
    dtype = torch::torch_long()
  ))
  importances <- tibble::tibble(
    variables = colnames(x),
    importance = compute_feature_importance(
      network,
      train_ds$.getbatch(batch =indexes)$x$to(device = "cpu"),
      train_ds$.getbatch(batch =indexes)$x_na_mask$to(device = "cpu")
    )
  )

  list(
    network = network,
    metrics = metrics,
    config = config,
    checkpoints = checkpoints,
    importances = importances
  )
}
