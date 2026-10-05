# Stable IDs establish identity; only the season-specific ADL player export supplies position.
resolve_nfl_realism_positions <- function(rosters, ids, mfl_players) {
  valid <- setdiff(nfl_realism_positions(), c("OL", "LS", "UNMAPPED"))
  mfl <- mfl_players |>
    dplyr::transmute(season, mfl_id = as.character(id), mfl_position = position,
      mfl_name = name, mfl_espn_id = as.character(espn_id), mfl_rotowire_id = as.character(rotowire_id))
  if (anyDuplicated(mfl[, c("season", "mfl_id")])) stop("Duplicate MFL season/player IDs.")
  # Index multiple independent shared IDs. Reject ambiguous mappings rather than taking first row.
  types <- intersect(c("gsis_id", "espn_id", "sportradar_id", "pfr_id", "rotowire_id"), names(ids))
  cross <- dplyr::bind_rows(lapply(types, function(type) {
    data.frame(id_type = type, id_value = as.character(ids[[type]]), mfl_id = as.character(ids$mfl_id))
  }))
  cross <- cross |> dplyr::filter(!is.na(id_value), nzchar(id_value), !is.na(mfl_id), nzchar(mfl_id)) |>
    dplyr::distinct() |> dplyr::group_by(id_type, id_value) |>
    dplyr::filter(dplyr::n_distinct(mfl_id) == 1) |> dplyr::ungroup()
  r <- rosters |> dplyr::mutate(record_id = dplyr::row_number())
  queries <- dplyr::bind_rows(lapply(intersect(types, names(r)), function(type) {
    data.frame(record_id = r$record_id, season = r$season, id_type = type, id_value = as.character(r[[type]]))
  })) |> dplyr::filter(!is.na(id_value), nzchar(id_value))
  candidates <- queries |> dplyr::inner_join(cross, by = c("id_type", "id_value"), relationship = "many-to-many") |>
    dplyr::inner_join(mfl, by = c("season", "mfl_id"), relationship = "many-to-many") |>
    dplyr::select(record_id, mfl_id, mfl_position, mfl_name, id_type)
  # Also use IDs carried directly by that year's MFL export, covering gaps in the crosswalk.
  for (type in intersect(c("espn_id", "rotowire_id"), names(r))) {
    direct <- mfl |> dplyr::transmute(season, mfl_id, mfl_position, mfl_name,
      id_value = .data[[paste0("mfl_", type)]]) |>
      dplyr::filter(!is.na(id_value), nzchar(id_value), id_value != "0")
    candidates <- dplyr::bind_rows(candidates,
      queries |> dplyr::filter(id_type == type) |>
        dplyr::inner_join(direct, by = c("season", "id_value"), relationship = "many-to-many") |>
        dplyr::select(record_id, mfl_id, mfl_position, mfl_name, id_type))
  }
  conflicts <- candidates |> dplyr::group_by(record_id) |>
    dplyr::summarise(mfl_candidates = dplyr::n_distinct(mfl_id), .groups = "drop")
  matched <- candidates |> dplyr::inner_join(dplyr::filter(conflicts, mfl_candidates == 1), by = "record_id") |>
    dplyr::group_by(record_id, mfl_id, mfl_position, mfl_name) |>
    dplyr::summarise(id_match_fields = paste(sort(unique(id_type)), collapse = "+"), .groups = "drop")
  r <- r |> dplyr::left_join(matched, by = "record_id") |>
    dplyr::left_join(conflicts, by = "record_id") |>
    dplyr::mutate(fallback_position = map_nfl_realism_position(position, depth_chart_position),
      non_adl = fallback_position %in% c("OL", "LS"))
  # Learn the fallback from distinct matched player-season classifications, not repeated weeks.
  schema <- r |> dplyr::filter(!non_adl, mfl_position %in% valid) |>
    dplyr::distinct(season, mfl_id, position, depth_chart_position, mfl_position) |>
    dplyr::count(season, position, depth_chart_position, mfl_position, name = "support") |>
    dplyr::group_by(season, position, depth_chart_position) |>
    dplyr::mutate(total_support = sum(support), confidence = support / total_support) |>
    dplyr::arrange(dplyr::desc(support), mfl_position, .by_group = TRUE) |>
    dplyr::slice_head(n = 1) |> dplyr::ungroup() |>
    dplyr::rename(estimated_position = mfl_position)
  r <- r |> dplyr::left_join(schema, by = c("season", "position", "depth_chart_position")) |>
    dplyr::mutate(adl_position = dplyr::case_when(
      non_adl ~ fallback_position,
      mfl_position %in% valid ~ mfl_position,
      !is.na(estimated_position) ~ estimated_position,
      TRUE ~ fallback_position),
      position_method = dplyr::case_when(non_adl ~ "NFL OL/LS",
        mfl_position %in% valid ~ "Season ADL/MFL ID match",
        !is.na(estimated_position) ~ "Estimated: season matched-player mode",
        TRUE ~ "Estimated: NFL depth-position translation"),
      estimate_reason = dplyr::case_when(non_adl ~ NA_character_,
        mfl_position %in% valid ~ NA_character_,
        mfl_candidates > 1 ~ "Conflicting ID candidates",
        !is.na(mfl_id) ~ "MFL position outside ADL individual positions",
        TRUE ~ "No season MFL ID match"))
  list(rosters = r, schema = schema)
}
