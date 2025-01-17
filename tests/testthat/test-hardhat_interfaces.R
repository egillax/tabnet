test_that("Training regression for data.frame and formula", {

  expect_error(
    fit <- tabnet_fit(x, y, epochs = 1),
    regexp = NA
  )

  expect_error(
    fit <- tabnet_fit(Sale_Price ~ ., data = ames, epochs = 1),
    regexp = NA
  )

  expect_error(
    predict(fit, x),
    regexp = NA
  )

  expect_error(
    fit <- tabnet_fit(x, y, epochs = 2, verbose = TRUE),
    regexp = NA
  )
})

test_that("Training classification for data.frame", {

  expect_error(
    fit <- tabnet_fit(attrix, attriy, epochs = 1),
    regexp = NA
  )

  expect_error(
    predict(fit, attrix, type = "prob"),
    regexp = NA
  )

  expect_error(
    predict(fit, attrix),
    regexp = NA
  )

})

test_that("works with validation split", {

  expect_error(
    fit <- tabnet_fit(attrix, attriy, epochs = 1, valid_split = 0.5),
    regexp = NA
  )

  expect_error(
    fit <- tabnet_fit(attrix, attriy, epochs = 1, valid_split = 0.5, verbose = TRUE),
    regexp = NA
  )

})


test_that("can train from a recipe", {

  rec <- recipe(Attrition ~ ., data = attrition) %>%
    step_normalize(all_numeric(), -all_outcomes())

  expect_error(
    fit <- tabnet_fit(rec, attrition[1:256,], epochs = 1, valid_split = 0.25,
                    verbose = TRUE),
    regexp = NA
  )

  expect_error(
    predict(fit, attrition),
    regexp = NA
  )

})

test_that("serialization with saveRDS just works", {

  predictions <-  predict(ames_fit, ames)

  tmp <- tempfile("model", fileext = "rds")
  withr::local_file(saveRDS(ames_fit, tmp))

  # rm(fit)
  gc()

  fit2 <- readRDS(tmp)

  expect_equal(
    predictions,
    predict(fit2, ames)
  )

  expect_equal(as.numeric(fit2$fit$network$.check), 1)

})

test_that("checkpoints works for inference", {

  expect_error(
    fit <- tabnet_fit(x, y, epochs = 3, checkpoint_epochs = 1),
    regexp = NA
  )

  expect_error(
    p1 <- predict(fit, x, epoch = 1),
    regexp = NA
  )

  expect_error(
    p2 <- predict(fit, x, epoch = 2),
    regexp = NA
  )

  expect_error(
    p3 <- predict(fit, x, epoch = 3),
    regexp = NA
  )

  expect_equal(p3, predict(fit, x))

})

test_that("print module works even after a reload from disk", {

  testthat::skip_on_os("linux")
  testthat::skip_on_os("windows")

  withr::with_options(new = c(cli.width = 50),
                      expect_snapshot_output(ames_fit))

  tmp <- tempfile("model", fileext = "rds")
  withr::local_file(saveRDS(ames_fit, tmp))
  fit2 <- readRDS(tmp)

  withr::with_options(new = c(cli.width = 50),
                      expect_snapshot_output(fit2))


})


test_that("num_workers works for pretrain, fit an predict", {

  expect_error(
    tabnet_pretrain(x, y, epochs = 1, num_workers=1L,
                                batch_size=65e3, virtual_batch_size=8192),
    regexp = NA
  )
  expect_error(
    tabnet_pretrain(x, y, epochs = 1, num_workers=1L, valid_split=0.2,
                                batch_size=65e3, virtual_batch_size=8192),
    regexp = NA
  )

  expect_error(
    tabnet_fit(x, y, epochs = 1, num_workers=1L,
                      batch_size=65e3, virtual_batch_size=8192),
    regexp = NA
  )

  expect_error(
    tabnet_fit(x, y, epochs = 1, num_workers=1L, valid_split=0.2,
                      batch_size=65e3, virtual_batch_size=8192),
    regexp = NA
  )

  expect_error(
    predict(ames_fit, x, num_workers=1L,
                      batch_size=65e3, virtual_batch_size=8192),
    regexp = NA
  )


})

