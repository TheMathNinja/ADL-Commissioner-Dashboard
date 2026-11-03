# Preserve commissioner-validated voids in the audit trail without creating
# compensating financial entries or suppressing another legitimate transaction.
apply_saladj_transaction_exceptions <- function(rows, season,
    exception_path=file.path('data',paste0('saladj_transaction_exceptions_',season,'.csv'))) {
  if (!file.exists(exception_path) || !nrow(rows)) return(rows)
  exceptions <- utils::read.csv(exception_path,colClasses='character',check.names=FALSE,
                                na.strings=character(),stringsAsFactors=FALSE)
  required <- c('exception_id','season','FRAN','DATE','PLAYER','SALARY','decision','reason')
  if (!all(required %in% names(exceptions))) stop('Invalid salary-adjustment exception ledger.')
  exceptions <- exceptions[exceptions$season==as.character(season),,drop=FALSE]
  if (!nrow(exceptions)) return(rows)
  if (anyDuplicated(exceptions$exception_id) || any(exceptions$decision!='VOID')) stop('Invalid or duplicate exception decision.')
  fields <- c('FRAN','DATE','PLAYER','SALARY')
  if (!all(fields %in% names(rows))) stop('Cannot match salary exceptions without transaction identity.')
  key <- function(x) {
    clean <- function(v) trimws(replace(as.character(v),is.na(v),''))
    dates <- as.POSIXct(clean(x$DATE),format='%m/%d/%Y %H:%M:%S',tz='America/New_York')
    salary <- suppressWarnings(as.numeric(gsub('[$,]','',clean(x$SALARY))))
    paste(toupper(clean(x$FRAN)),format(dates,'%Y-%m-%d %H:%M:%S'),
          tolower(clean(x$PLAYER)),sprintf('%.2f',salary),sep='|')
  }
  valid_dates <- as.POSIXct(exceptions$DATE,format='%m/%d/%Y %H:%M:%S',tz='America/New_York')
  if (anyNA(valid_dates) || anyNA(suppressWarnings(as.numeric(exceptions$SALARY)))) stop('Invalid exception transaction date or salary.')
  ek <- key(exceptions);rk <- key(rows)
  if (anyDuplicated(ek)) stop('Ambiguous salary-adjustment exception identity.')
  if (!'RVSD?' %in% names(rows)) rows[['RVSD?']] <- ''
  if (!'NOTES' %in% names(rows)) rows$NOTES <- ''
  for (i in seq_len(nrow(exceptions))) {
    matched <- which(rk==ek[[i]])
    if (length(matched)>1L) stop('Multiple transactions match one salary exception; manual review required.')
    if (!length(matched)) next
    rows[['RVSD?']][matched] <- 'x'
    note <- paste0('COMMISSIONER EXCEPTION [',exceptions$exception_id[[i]],']: ',exceptions$reason[[i]])
    prior <- as.character(rows$NOTES[matched]);if (is.na(prior)) prior <- ''
    if (!grepl(note,prior,fixed=TRUE)) rows$NOTES[matched] <- paste(c(prior[nzchar(prior)],note),collapse='; ')
  }
  rows
}
