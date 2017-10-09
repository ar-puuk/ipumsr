# This file is part of the Minnesota Population Center's ripums.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/mnpopcenter/ripums


#' Read boundary files from an IPUMS extract
#'
#' Reads the boundary files from an IPUMS extract into R as simple features (sf) objects or
#' SpatialPolygonsDataFrame (sp) objects.
#'
#' @param shape_file Filepath to one or more .shp files or a .zip file from an IPUMS extract
#' @param shape_layer For .zip extracts with multiple datasets, the name of the
#'   shape files to load. Accepts a character vector specifying the file name, or
#'  \code{\link{dplyr_select_style}} conventions. Can load multiple shape files,
#'    which will be combined.
#' @param bind_multiple If \code{TRUE}, will combine multiple shape files found into
#'   a single object.
#' @param verbose I \code{TRUE}, will report progress information
#' @return \code{read_ipums_sf} returns a sf object and \code{read_ipums_sp} returns
#'   a SpatialPolygonsDataFrame.
#' @examples
#' shape_file <- ripums_example("nhgis0008_shape_small.zip")
#' # If sf package is availble, can load as sf object
#' if (require(sf)) {
#'   sf_data <- read_ipums_sf(shape_file)
#' }
#'
#' # If sp package is available, can load as SpatialPolygonsDataFrame
#' if (require(sp)) {
#'   sp_data <- read_ipums_sp(shape_file)
#' }
#'
#' @family ipums_read
#' @export
read_ipums_sf <- function(shape_file, shape_layer = NULL, bind_multiple = TRUE, verbose = TRUE) {
  shape_layer <- enquo(shape_layer)
  load_sf_namespace()

  # Case 1: Shape file specified is a .zip file
  shape_is_zip <- stringr::str_sub(shape_file, -4) == ".zip"
  if (shape_is_zip) {
    read_shape_files <- character(0) # Start with empty list of files to read
    # Case 1a: First zip file has zip files of shape files within it
    shape_zips <- find_files_in_zip(shape_file, "zip", shape_layer, multiple_ok = TRUE)

    if (!bind_multiple && length(shape_zips) > 1) {
      stop(paste0(
        "Multiple shape files found, please set the `bind_multiple` argument to `TRUE`",
        " to combine them together, or use the `shape_layer` argument to specify a",
        " single layer.\n", paste(shape_zips, collapse = ", ")
      ))
    }

    if (length(shape_zips) >= 1) {
      shape_temp <- tempfile()
      dir.create(shape_temp)
      on.exit(unlink(shape_temp, recursive = TRUE))

       purrr::walk(shape_zips, function(x) {
        utils::unzip(shape_file, x, exdir = shape_temp)
        utils::unzip(file.path(shape_temp, x), exdir = shape_temp)
      })
       read_shape_files <- dir(shape_temp, "\\.shp$", full.names = TRUE)
    }

    # Case 1b: First zip file has .shp files within it
    if (length(read_shape_files) == 0) {
      shape_shps <- find_files_in_zip(shape_file, "shp", shape_layer, multiple_ok = TRUE)

      if (!bind_multiple && length(shape_shps) > 1) {
        stop(paste0(
          "Multiple shape files found, please set the `bind_multiple` argument to `TRUE`",
          " to combine them together, or use the `shape_layer` argument to specify a",
          " single layer.\n", paste(shape_shps, collapse = ", ")
        ))
      }

      if (length(shape_shps) >= 1) {
        shape_temp <- tempfile()
        dir.create(shape_temp)
        on.exit(unlink(shape_temp, recursive = TRUE))

        read_shape_files <- purrr::map_chr(shape_shps, function(x) {
          shape_shp_files <- paste0(
            stringr::str_sub(x, 1, -4),
            # ignore  "sbn", "sbx" because R doesn't use them
            c("shp", "dbf", "prj", "shx")
          )

          utils::unzip(shape_file, shape_shp_files, exdir = shape_temp)

          # If there is a cpg file (encoding information) extract that
          all_files <- utils::unzip(shape_file, list = TRUE)$Name
          cpg_file <- ".cpg" == tolower(purrr::map_chr(all_files, ipums_file_ext))
          if (any(cpg_file)) {
            utils::unzip(shape_file, all_files[cpg_file], exdir = shape_temp)
          }

          file.path(shape_temp, shape_shp_files[1])
        })
      }

      if (length(read_shape_files) == 0) {
        stop(call. = FALSE, paste0(
          "Zip file not formatted as expected. Please check your `shape_layer`",
          "argument or unzip and try again."
        ))
      }
    }
  }

  # Case 2: Shape file specified is a .shp file
  shape_is_shp <- stringr::str_sub(shape_file, -4) == ".shp"
  if (shape_is_shp) {
    read_shape_files <- shape_file
  }

  if (!shape_is_zip & !shape_is_shp) {
    stop("Expected `shape_file` to be a .zip or .shp file.")
  }

  encoding <- get_encoding_from_cpg(read_shape_files)

  out <- purrr::map2(
    read_shape_files,
    encoding,
    ~sf::read_sf(.x, quiet = !verbose, options = paste0("ENCODING=", .y))
  )
  out <- careful_sf_rbind(out)

  out
}

# Takes a list of sf's, fills in empty columns for you and binds them together.
# Throws error if types don't match
careful_sf_rbind <- function(sf_list) {
  if (length(sf_list) == 1) {
    return(sf_list[[1]])
  } else {
    # Get var info for all columns
    all_var_info <- purrr::map_df(sf_list, .id = "id", function(x) {
      tibble::data_frame(name = names(x), type = purrr::map(x, ~class(.)))
    })

    var_type_check <- dplyr::group_by(all_var_info, .data$name)
    var_type_check <- dplyr::summarize(var_type_check, check = length(unique(.data$type)))
    if (any(var_type_check$check != 1)) {
      stop("Cannot combine shape files because variable types don't match.")
    }

    all_var_info$id <- NULL
    all_var_info <- dplyr::distinct(all_var_info)

    out <- purrr::map(sf_list, function(x) {
      missing_vars <- dplyr::setdiff(all_var_info$name, names(x))
      if (length(missing_vars) == 0) return(x)

      for (vn in missing_vars) {
        vtype <- all_var_info$type[all_var_info$name == vn][[1]]
        if (identical(vtype, "character")) x[[vn]] <- NA_character_
        else if (identical(vtype, "numeric")) x[[vn]] <- NA_real_
        else if (identical(vtype, c("sfc_MULTIPOLYGON", "sfc"))) x[[vn]] <- vector("list", nrow(x))
        else stop("Unexpected variable type in shape file.")
      }
      x
    })
    out <- do.call(rbind, out)
  }
  sf::st_as_sf(tibble::as.tibble(out))
}


#' @rdname read_ipums_sf
#' @export
read_ipums_sp <- function(shape_file, shape_layer = NULL, bind_multiple = TRUE, verbose = TRUE) {
  shape_layer <- enquo(shape_layer)
  load_rgdal_namespace()

  # Case 1: Shape file specified is a .zip file
  shape_is_zip <- stringr::str_sub(shape_file, -4) == ".zip"
  if (shape_is_zip) {
    read_shape_files <- character(0) # Start with empty list of files to read
    # Case 1a: First zip file has zip files of shape files within it
    shape_zips <- find_files_in_zip(shape_file, "zip", shape_layer, multiple_ok = TRUE)

    if (!bind_multiple && length(shape_zips) > 1) {
      stop(paste0(
        "Multiple shape files found, please set the `bind_multiple` argument to `TRUE`",
        " to combine them together, or use the `shape_layer` argument to specify a",
        " single layer.\n", paste(shape_zips, collapse = ", ")
      ))
    }

    if (length(shape_zips) >= 1) {
      shape_temp <- tempfile()
      dir.create(shape_temp)
      on.exit(unlink(shape_temp, recursive = TRUE))

      purrr::walk(shape_zips, function(x) {
        utils::unzip(shape_file, x, exdir = shape_temp)
        utils::unzip(file.path(shape_temp, x), exdir = shape_temp)
      })
      read_shape_files <- dir(shape_temp, "\\.shp$", full.names = TRUE)
    }

    # Case 1b: First zip file has .shp files within it
    if (length(read_shape_files) == 0) {
      shape_shps <- find_files_in_zip(shape_file, "shp", shape_layer, multiple_ok = TRUE)

      if (!bind_multiple && length(shape_shps) > 1) {
        stop(paste0(
          "Multiple shape files found, please set the `bind_multiple` argument to `TRUE`",
          " to combine them together, or use the `shape_layer` argument to specify a",
          " single layer.\n", paste(shape_shps, collapse = ", ")
        ))
      }

      if (length(shape_shps) >= 1) {
        shape_temp <- tempfile()
        dir.create(shape_temp)
        on.exit(unlink(shape_temp, recursive = TRUE))

        read_shape_files <- purrr::map_chr(shape_shps, function(x) {
          shape_shp_files <- paste0(
            stringr::str_sub(x, 1, -4),
            # ignore "sbn", "sbx" because R doesn't use them
            c("shp", "dbf", "prj", "shx")
          )

          utils::unzip(shape_file, shape_shp_files, exdir = shape_temp)

          # If there is a cpg file (encoding information) extract that
          all_files <- utils::unzip(shape_file, list = TRUE)$Name
          cpg_file <- ".cpg" == tolower(purrr::map_chr(all_files, ipums_file_ext))
          if (any(cpg_file)) {
            utils::unzip(shape_file, all_files[cpg_file], exdir = shape_temp)
          }

          file.path(shape_temp, shape_shp_files[1])
        })
      }

      if (length(read_shape_files) == 0) {
        stop(call. = FALSE, paste0(
          "Zip file not formatted as expected. Please check your `shape_layer`",
          "argument or unzip and try again."
        ))
      }
    }
  }

  # Case 2: Shape file specified is a .shp file
  shape_is_shp <- stringr::str_sub(shape_file, -4) == ".shp"
  if (shape_is_shp) {
    read_shape_files <- shape_file
  }

  if (!shape_is_zip & !shape_is_shp) {
    stop("Expected `shape_file` to be a .zip or .shp file.")
  }

  encoding <- get_encoding_from_cpg(read_shape_files)

  out <- purrr::map2(
    read_shape_files,
    encoding,
    ~rgdal::readOGR(
      dsn = dirname(.x),
      layer = stringr::str_sub(basename(.x), 1, -5),
      verbose = verbose,
      stringsAsFactors = FALSE,
      encoding = .y
    )
  )
  out <- careful_sp_rbind(out)

  out
}


# Takes a list of SpatialPolygonsDataFrames, fills in empty columns for you and binds
# them together.
# Throws error if types don't match
careful_sp_rbind <- function(sp_list) {
  if (length(sp_list) == 1) {
    return(sp_list[[1]])
  } else {
    # Get var info for all columns
    all_var_info <- purrr::map_df(sp_list, .id = "id", function(x) {
      tibble::data_frame(name = names(x@data), type = purrr::map(x@data, ~class(.)))
    })

    var_type_check <- dplyr::group_by(all_var_info, .data$name)
    var_type_check <- dplyr::summarize(var_type_check, check = length(unique(.data$type)))
    if (any(var_type_check$check != 1)) {
      stop("Cannot combine shape files because variable types don't match.")
    }

    all_var_info$id <- NULL
    all_var_info <- dplyr::distinct(all_var_info)

    out <- purrr::map(sp_list, function(x) {
      missing_vars <- dplyr::setdiff(all_var_info$name, names(x))
      if (length(missing_vars) == 0) return(x)

      for (vn in missing_vars) {
        vtype <- all_var_info$type[all_var_info$name == vn][[1]]
        if (identical(vtype, "character")) x@data[[vn]] <- NA_character_
        else if (identical(vtype, "numeric")) x@data[[vn]] <- NA_real_
        else stop("Unexpected variable type in shape file.")
      }
      x
    })
    out <- do.call(rbind, out)
  }
  out
}

# Encoding:
# Official spec is that shape files must be latin1. But some GIS software
# add to the spec a cpg file that can specify an encoding.
## NHGIS: Place names in 2010 have accents - and are latin1 encoded,
##        No indication of encoding.
## IPUMSI: Brazil has a cpg file indicating the encoding is ANSI 1252,
##         while China has UTF-8 (but only english characters)
## USA:   Also have cpg files.
## Terrapop Brazil has multi-byte error characters for the data.
# Current solution: Assume latin1, unless I find a CPG file and
# with encoding I recognize and then use that.
get_encoding_from_cpg <- function(shape_file_vector) {
  out <- purrr::map_chr(shape_file_vector, function(x) {
    cpg_file <- dir(dirname(x), pattern = "\\.cpg$", ignore.case = TRUE, full.names = TRUE)

    if (length(cpg_file) == 0) return("latin1")

    cpg_text <- readr::read_lines(cpg_file)[1]
    if (stringr::str_detect(cpg_text, "ANSI 1252")) return("CP1252")
    else if (stringr::str_detect(cpg_text, "UTF[[-][|:blank:]]?8")) return("UTF-8")
    else return("latin1")
  })
  out
}


ipums_shape_join <- function(
  data,
  shape_data,
  by,
  direction = c("full", "inner", "left", "right"),
  suffix = c("", "_SHAPE"),
  verbose = TRUE
) {
  UseMethod("ipums_shape_join", shape_data)
}

ipums_shape_join.sf <- function(
  data,
  shape_data,
  by,
  direction = c("full", "inner", "left", "right"),
  suffix = c("", "_SHAPE"),
  verbose = TRUE
) {
  if (!is.null(names(by))) {
    by_shape <- by
    by_data <- by
  } else {
    by_shape <- names(by)
    by_data <- unname(by)
  }

  not_in_shape <- dplyr::setdiff(by_shape, names(shape_data))
  if (length(not_in_shape) > 0) {
    stop(paste0("Variables ", paste(not_in_shape, collapse = ", "), " are not in shape data."))
  }
  not_in_data <- dplyr::setdiff(by_shape, names(data))
  if (length(not_in_shape) > 0) {
    stop(paste0("Variables ", paste(not_in_data, collapse = ", "), " are not in data."))
  }
  direction <- match.arg(direction)

  # We're pretending like the x in the join is the data, but
  # because of the join functions dispatch, we will actually be
  # doing the reverse. Therefore, rename the variables in shape,
  # and also reverse the suffix.
  if (!is.null(names(by))) {
    shape_data <- dplyr::rename(shape_data, !!!rlang::syms(by))
    by <- names(by)
  }
  suffix <- rev(suffix)

  # Allign variable attributes
  shp_id_is_char <- purrr::map_lgl(by, ~is.character(shape_data[[.]]))
  data_id_is_char <- purrr::map_lgl(by, ~is.character(data[[.]]))
  convert_failures <- rep(FALSE, length(by))
  for (iii in seq_along(by)) {
    # If one is character but other is numeric, convert if possible
    if (shp_id_is_char[iii] && !data_id_is_char[iii]) {
      shape_data[[by[iii]]] <- custom_parse_number(shape_data[[by[iii]]])
      if (is.character(shape_data[[by[iii]]])) convert_failures[iii] <- TRUE
    } else if (!shp_id_is_char[iii] && data_id_is_char[iii]) {
      data[[by[iii]]] <- custom_parse_number(data[[by[iii]]])
      if (is.character(shape_data[[by[iii]]])) convert_failures[iii] <- TRUE
    }

    if (any(convert_failures)) {
      bad_shape <- by_shape[convert_failures]
      bad_data <- by_data[convert_failures]
      text <- ifelse(bad_shape != bad_data, paste0(bad_shape, " -> ", bad_data), bad_shape)
      stop(paste0(
        "Variables were numeric in one object but character in the other and ",
        "could not be converted:\n", paste(text, collapse = ", ")
      ))
    }

    #Combine attributes (prioritzing data attributes because the DDI has more info)
    shape_attr <- attributes(shape_data[[by[iii]]])
    data_attr <- attributes(data[[by[iii]]])

    overlapping_attr <- dplyr::intersect(names(shape_attr), names(data_attr))
    shape_attr <- shape_attr[!names(shape_attr) %in% overlapping_attr]

    all_attr <- c(data_attr, shape_attr)
    attributes(shape_data[[by[iii]]]) <- all_attr
    attributes(data[[by[iii]]]) <- all_attr
  }

  merge_f <- utils::getFromNamespace(paste0(direction, "_join"), "dplyr")
  out <- merge_f(shape_data, data, by = by, suffix = suffix)

  # message for merge failures
  if (verbose) {
    merge_fail <- list(
      shape = dplyr::anti_join(shape_data, as.data.frame(out), by = by),
      data = dplyr::anti_join(data, out, by = by)
    )
    sh_num <- nrow(merge_fail$shape)
    d_num <- nrow(merge_fail$data)
    if (sh_num > 0 | d_num > 0) {
      if (sh_num > 0 && d_num > 0) {
        count_message <- paste0(sh_num, " observations in the shape file and ", d_num, " obervation in data")
      } else if (sh_num > 0) {
        count_message <- paste0(sh_num, " observations in the shape file")
      } else if (d_num > 0) {
        count_message <- paste0(d_num, " observations in the data")
      }
      cat(paste0(
        "Some observations were lost in the join (", count_message, "). See `join_problems(...)` for more details."
      ))
      attr(out, "join_problems") <- merge_fail
    }
  }
  out
}

get_unique_values <- function(x) {
  x <- dplyr::select(x, starts_with("RIPUMS_GEO_JOIN_VAR"))
  x <- dplyr::group_by(x, !!!rlang::syms(names(x)))
  x <- dplyr::summarize(x, n = !!rlang::quo(n()))
  x
}

check_for_uniqueness <- function(x, type) {
  x <- get_unique_values(x)
  x_dups <- dplyr::filter(x, n > 1)
  if (nrow(x_dups) > 1) {
    tbl_msg <- tbl_print_for_message(x_dups)
    stop(paste0("IDs do not uniquely identify observations in", type, ".\n", tbl_msg))
  }
  x
}
