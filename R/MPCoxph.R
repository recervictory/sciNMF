#' Cox Proportional Hazards Regression for MetaPrograms
#'
#' Perform Cox proportional hazards regression for a set of meta-programs (gene sets) on survival data.
#'
#' @param mat.exp The gene expression matrix with genes as rows and samples as columns.
#' @param cli A data.frame contains clinical data with survival information, including time-to-event (time) and event status (event).
#' @param gene.list A list of gene sets (meta-programs) with each element containing the genes in a meta-program.
#' @param time The column name in the \code{cli} data.frame that represents the time-to-event (survival time). Default is "OS.time"
#' @param event The column name in the \code{cli} data.frame that represents the event status (event occurrence).
#' This column should contain binary values (0 or 1), where 0 indicates that the event has not occurred (alive) and 1 indicates that the event has occurred (dead).
#' @param group.by A character vector specifying the column names in the \code{cli} data.frame that will be used to split the samples for subgroup analysis. If set to NULL, all samples will be treated as one group.
#' @param min.sample The minimum number of samples required in each subgroup for Cox regression analysis. Default is 15.
#' @param return.df A logical value indicating whether to return the result as a data frame (TRUE) or as a ggplot object (FALSE).
#' @param xlab The label for the x-axis of the plot. Default is "Program".
#' @param ylab The label for the y-axis of the plot. Default is "Group".
#' @param titile The title of the plot. Default is "Univariate Cox Regression".
#' @param color.asterisks The color for indicating the significance level of each meta-program.
#' @param show.ns  A logical value indicating whether to show ns (no significant).
#' @param score.method The method used to calculate the meta-program score, which can be one of "ssgsea", "gsva", "plage", or "average".
#' @param kcdf Character string denoting the kernel to use during the non-parametric estimation of the cumulative distribution function of expression levels across samples when method="gsva". By default, kcdf="Gaussian". More details are in \code{GSVA::\link[GSVA]{gsva}}.
#'
#' @return A ggplot object representing the Cox proportional hazards regression results for meta-programs.
#' The significance level of each meta-program is indicated by the number of asterisks (*) as follows:
#' \itemize{ \item\code{ns}: p > 0.05 \item\code{*}: p <= 0.05 \item \code{**}: p <= 0.01 \item \code{***}: p <= 0.001 \item \code{****}:  p <= 0.0001 }
#'
#' @import ggplot2
#' @import GSVA
#' @importFrom paletteer paletteer_d
#' @importFrom survival coxph Surv
#' @importFrom stats setNames
#' @importFrom grDevices colorRampPalette
#' @importFrom dplyr arrange
#'
#' @seealso
#' \code{\link[ggplot2]{ggplot}} for customizing the plot appearance.
#'
#' \code{\link[GSVA]{gsva}} for scoring the samples by the programs.
#'
#' \code{\link[survival]{coxph}} for univariate cox regression
#'
#' @export
#'
MPCoxph <- function(mat.exp, cli, gene.list, time = "OS.time", event = "OS.status", group.by = NULL, min.sample = 15, return.df = FALSE,
                    xlab = "MetaProgram", ylab = "Group", titile = "Univariate Cox Regression", color.asterisks = "white", show.ns = FALSE,
                    score.method = "ssgsea", kcdf = "Gaussian") {
  # check the input
  if (!all(rownames(cli) %in% colnames(mat.exp))) {
    warning("Some patients in cli are not found in mat.exp")
  }

  if (is.null(group.by)) {
    ls_cli <- list(Data = cli)
  }
  cli <- cli[, c(group.by, event, time)]
  colnames(cli) <- c(group.by, "event", "time")
  mat.exp <- as.matrix(mat.exp[, rownames(cli)])

  # split the samples by group.by
  if (is.null(group.by)) {
    cli$Group <- "Data"
  } else {
    cli$Group <- cli[, group.by, drop = FALSE] %>% apply(1, paste, collapse = "_")
  }

  ls_cli <- split(cli, cli$Group)

  if (any(table(cli$Group) < min.sample)) {
    groups <- names(table(cli$Group))[table(cli$Group) < min.sample]
    warning("Removed group ", paste(groups, collapse = " "), " for less than ", min.sample, " samples")
    ls_cli <- ls_cli[table(cli$Group) >= min.sample]
  }

  # add the meta program score
  ls_cli <- lapply(setNames(names(ls_cli), names(ls_cli)), function(group) {
    sub_cli <- ls_cli[[group]]
    sub_exp <- mat.exp[, rownames(sub_cli)]

    # calculate the score for each subgroup
    if (score.method %in% c("ssgsea", "gsva", "plage")) {
      cat("Calculating scores for Group", group, "\n")

      # check GSVA version
      if (packageVersion("GSVA") < "1.50.0") {
        sub_score <- GSVA::gsva(
          expr = sub_exp, gset.idx.list = gene.list,
          method = score.method, kcdf = kcdf
        ) %>% t()
      } else {
        if (score.method == "ssgsea") {
          obj_gsva <- GSVA::ssgseaParam(exprData = sub_exp, geneSets = gene.list)
        }
        if (score.method == "gsva") {
          obj_gsva <- GSVA::gsvaParam(exprData = sub_exp, geneSets = gene.list, kcdf = kcdf)
        }
        if (score.method == "plage") {
          obj_gsva <- GSVA::plageParam(exprData = sub_exp, geneSets = gene.list)
        }

        sub_score <- GSVA::gsva(obj_gsva) %>% t()
      }
    } else if (score.method == "average") {
      sub_score <- sapply(gene.list, function(gs) {
        gs <- intersect(gs, rownames(sub_exp))
        colMeans(sub_exp[gs, ])
      })
    } else {
      stop("Ivalid score.method, must be one of ssgsea, gsva, plage, average")
    }

    cbind(sub_cli, sub_score)
  })


  # perform cox regresion
  df_pl <- lapply(names(ls_cli), function(group) {
    sub_cli <- ls_cli[[group]]

    # each program
    lapply(names(gene.list), function(sig) {
      sub_cli$Score <- sub_cli[, sig]
      res_cox <- survival::coxph(survival::Surv(time, event) ~ Score, data = sub_cli) %>% summary()

      data.frame(
        Group = group, Signature = sig,
        Cindex = res_cox$concordance[1],
        HR = res_cox$coefficients[, "exp(coef)"],
        pvalue = res_cox$coefficients[, "Pr(>|z|)"]
      )
    }) %>% do.call(what = rbind)
  }) %>% do.call(what = rbind)

  df_pl$Significance <- cut(df_pl$pvalue,
    breaks = c(0, 0.0001, 0.001, 0.01, 0.05, 1),
    labels = c("****", "***", "**", "*", "ns")
  )
  if (!show.ns) {
    df_pl$Significance <- gsub("ns", "", df_pl$Significance)
  }

  GroupSize <- stats::setNames(sapply(ls_cli, nrow), names(ls_cli))
  df_pl$GroupName <- df_pl$Group
  df_pl$GroupSize <- GroupSize[df_pl$Group]
  df_pl$Group <- paste0(df_pl$Group, "_(n=", df_pl$GroupSize, ")")
  df_pl <- dplyr::arrange(df_pl, -Cindex)

  if (return.df) {
    rownames(df_pl) <- NULL
    return(df_pl)
  }

  # The lower limit is set to 0 and the upper limit to 80%
  lim_up <- sort(df_pl$HR)[round(0.8 * nrow(df_pl))]
  # The upper limit is set to 4
  lim_up <- min(lim_up, 4)
  # Prevent all less than 1, the minimum threshold is 2
  lim_up <- max(lim_up, 2)
  # generate the colors
  n_cut <- 5 * (lim_up - 1)
  RdYlBu_r <- as.character(rev(paletteer::paletteer_d("RColorBrewer::RdYlBu")))
  hr_color1 <- RdYlBu_r[1:5]
  hr_color2 <- grDevices::colorRampPalette(RdYlBu_r[6:11])(n_cut)
  hr_color <- c(hr_color1, hr_color2)

  df_pl$TrueHR <- df_pl$HR
  df_pl$HR <- ifelse(df_pl$HR > lim_up, lim_up, df_pl$HR)

  rownames(df_pl) <- NULL

  pl <- ggplot(df_pl, aes(Signature, Group)) +
    geom_point(aes(color = HR, size = Cindex)) +
    scale_color_gradientn(
      limits = c(0, lim_up),
      colors = hr_color
    ) +
    geom_text(aes(label = Significance),
      vjust = 0.6, hjust = 0.5,
      color = color.asterisks, fontface = "bold"
    ) +
    theme_bw() +
    ggtitle(titile) +
    theme(
      plot.title = element_text(hjust = 0.5),
      axis.text.x = element_text(vjust = 0.5, hjust = 1, angle = 90)
    ) +
    xlab(xlab) +
    ylab(ylab)

  return(pl)
}
