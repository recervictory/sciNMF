#' Single-Cell Integration by Non-Negative Matrix Factorization(sciNMF)
#'
#' This function performs non-negative matrix factorization (NMF) analysis
#' on single-cell gene expression matrix for each individual.
#'
#' @param object a Seurat object.
#' @param group.by name of the column in metadata used for grouping cells.
#' @param dir.output directory to save the output files, default is NULL. If provided, the NMF result of each individual will be saved as .rds files.
#' @param k.range range of values for the number of modules (k) in NMF, default is 3:8.
#' @param samples samples to analyze, default is NULL and all the samples in group.by column will be analyzed.
#' @param project prefix for transcriptional programs and the output files, default is 'NMF'.
#' @param normalization.method normalization method for the data, one of 'SCT' or 'LogNormalize', default is 'SCT'.
#' @param min.cell minimum number of cells required for analysis in an individual, default is 10.
#' @param variable.features.n number of high variable features to select for each individual.
#' @param do.scale logical, indicating whether to scale the data, default is FALSE.
#' @param do.center logical, indicating whether to center the data, default is TRUE.
#' @param ncore number of cores for parallel computation.
#' @param seed random seed for reproducibility.
#' @param rm.MT logical, indicating whether to remove mitochondrial genes.
#' @param rm.RP.S.L logical, indicating whether to remove ribosomal protein genes.
#' @param rm.HSP logical, indicating whether to remove heat shock protein genes.
#' @param loss loss function for \code{NNLM::\link[NNLM]{nnmf}}, either mean square error (mse) or mean KL-divergence (mkl), default is 'mse'.
#' @param max.iter maximum number of iterations for \code{NNLM::\link[NNLM]{nnmf}}, default is 5000.
#' @param method method for \code{NNLM::\link[NNLM]{nnmf}} computation, default is 'scd'.
#' @param ... Additional arguments for \code{NNLM::\link[NNLM]{nnmf}}.
#'
#' @return A list of matrices containing the NMF results named by individuals in group.by column; for each individual, H and W matrices will be returned.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' ls_WH <- RunNMF(SeuratObject, group.by = "Patient")
#' }
#'
#' @seealso \code{NNLM::\link[NNLM]{nnmf}}
#'
#' @seealso For more information, please refer to \url{https://github.com/Tang-RH/sciNMF}
#' @importFrom Matrix rowSums
#' @importFrom Seurat CreateSeuratObject SCTransform GetAssayData NormalizeData FindVariableFeatures ScaleData VariableFeatures
#' @importFrom foreach foreach '%dopar%'
#' @importFrom doParallel registerDoParallel
#' @importFrom NNLM nnmf
#' @importFrom methods as
#' @importFrom stats var
#' @references
#' Seurat: \url{https://satijalab.org/seurat/}
#' @references
#' NNLM: \url{https://github.com/linxihui/NNLM/}

RunNMF <- function(object, group.by, dir.output = NULL, k.range = 3:8, samples = NULL, project = "NMF",
                   normalization.method = "SCT", min.cell = 10, variable.features.n = 7000,
                   do.scale = FALSE, do.center = TRUE,
                   ncore = 1, seed = 123,
                   rm.MT = TRUE, rm.RP.S.L = TRUE, rm.HSP = TRUE,
                   loss = "mse", max.iter = 5000, method = "scd", ...) {
  # check the version of SeuratObject
  flag_v <- packageVersion("SeuratObject") >= "5"

  if (any(is.na(object@meta.data[, group.by]))) {
    warning("The ", group.by, " column contains NA and those cells are removed!")
    idx_cell <- !is.na(object@meta.data[, group.by])
    object <- object[, idx_cell]
  }

  if (is.null(samples)) {
    samples <- unique(object@meta.data[, group.by])
  }

  if (flag_v) {
    genes <- rownames(Seurat::GetAssayData(object, assay = "RNA", layer = "counts"))
  } else {
    genes <- rownames(Seurat::GetAssayData(object, assay = "RNA", slot = "counts"))
  }

  # remove MT, RP, HSP genes
  if (rm.MT) {
    genes <- grep("^MT-", genes, invert = TRUE, value = TRUE)
  }
  if (rm.RP.S.L) {
    genes <- grep("^RP[SL]", genes, invert = TRUE, value = TRUE)
  }
  if (rm.HSP) {
    genes <- grep("^HSP", genes, invert = TRUE, value = TRUE)
  }


  if (flag_v) {
    clean_counts <- Seurat::GetAssayData(object, assay = "RNA", layer = "counts")[genes, ]
  } else {
    clean_counts <- Seurat::GetAssayData(object, assay = "RNA", slot = "counts")[genes, ]
  }


  doParallel::registerDoParallel(cores = ncore)

  ls_res <- foreach(sam = samples) %dopar% {
    message("Start sample ", sam, " -- Current time:", as.character(Sys.time()))
    idx_cell <- object@meta.data[, group.by] == sam

    if (sum(idx_cell) < min.cell) {
      message("Sample ", sam, " has only ", sum(idx_cell), " cells less than ", min.cell, " cells, skip it\n")
      return(NULL)
    }

    idx_0_gene <- Matrix::rowSums(clean_counts[, idx_cell]) == 0

    srt <- Seurat::CreateSeuratObject(counts = clean_counts[!idx_0_gene, idx_cell], meta.data = object@meta.data[idx_cell, ])

    if (normalization.method == "SCT") {
      # I don't know why warning for Seurat::SCTransform()
      srt <- SCTransform(srt,
        verbose = FALSE, do.scale = do.scale,
        do.center = do.center, variable.features.n = variable.features.n
      )
      if (flag_v) {
        data <- Seurat::GetAssayData(srt, assay = "SCT", layer = "scale.data")
      } else {
        data <- Seurat::GetAssayData(srt, assay = "SCT", slot = "scale.data")
      }
    } else if (normalization.method == "LogNormalize") {
      srt <- Seurat::NormalizeData(srt, normalization.method = "LogNormalize", scale.factor = 10000)
      srt <- Seurat::FindVariableFeatures(srt, selection.method = "vst", nfeatures = variable.features.n)
      srt <- Seurat::ScaleData(srt,
        features = VariableFeatures(srt),
        do.scale = do.scale, do.center = do.center
      )

      if (flag_v) {
        data <- Seurat::GetAssayData(srt, assay = "RNA", layer = "scale.data")
      } else {
        data <- Seurat::GetAssayData(srt, assay = "RNA", slot = "scale.data")
      }
    } else {
      stop("Invalid normalization.method, must be one of SCT, LogNormalize")
    }


    data <- data[Seurat::VariableFeatures(srt), ]
    data[data < 0] <- 0
    data <- data[apply(data, 1, var) > 0, ]

    ls_WH <- lapply(k.range, function(k) {
      set.seed(seed)
      res_nmf <- NNLM::nnmf(data, k = k, loss = loss, max.iter = max.iter, method = method, ...)
      H <- res_nmf$H
      W <- res_nmf$W
      rownames(H) <- colnames(W) <- paste0(project, "_", sam, "_K", k, "_P", 1:k)
      return(list(H = H, W = W))
    })

    all_W <- lapply(ls_WH, function(WH) {
      WH$W
    }) %>% do.call(what = cbind)
    all_H <- lapply(ls_WH, function(WH) {
      WH$H
    }) %>% do.call(what = rbind)
    WHs <- list(W = all_W, H = all_H)

    if (!is.null(dir.output)) {
      if (!file.exists(dir.output)) {
        dir.create(dir.output, recursive = TRUE)
      }
      saveRDS(WHs, paste0(
        dir.output, "/", project, "_", sam, "_hvg", variable.features.n,
        "_k", k.range[1], "to", tail(k.range, 1), ".rds"
      ))
    }
    message("Sample ", sam, " done!")
    return(WHs)
  }
  names(ls_res) <- samples
  ls_res <- ls_res[!sapply(ls_res, is.null)]
  message("All Done!")
  return(ls_res)
}
