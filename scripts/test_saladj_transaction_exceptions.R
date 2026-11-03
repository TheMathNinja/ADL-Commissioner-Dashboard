source('R/saladj_transaction_exceptions.R')
rows <- data.frame(FRAN=c('KCC','LVR','KCC','KCC','MIN'),
 DATE=c('10/21/2026 13:22:02','10/21/2026 13:22:02','10/21/2026 13:25:02','10/22/2026 14:55:57','11/3/2026 00:39:46'),
 PLAYER=c('Cash Trade','Cash Trade','Kyle Dugger','Kyle Dugger','Sam Darnold'),
 SALARY=c('-1.7','1.7','7.08','7.08','24.98'),NOTES='',check.names=FALSE)
rows[['RVSD?']] <- ''

out <- apply_saladj_transaction_exceptions(rows,2026)
changed <- which(out[['RVSD?']]!=rows[['RVSD?']])
stopifnot(length(changed)==3L,nrow(out)==nrow(rows),identical(rows$DATE,out$DATE),identical(rows$SALARY,out$SALARY))
stopifnot(all(out[['RVSD?']][changed]=='x'),all(grepl('COMMISSIONER EXCEPTION',out$NOTES[changed],fixed=TRUE)))
valid_drop <- which(out$FRAN=='KCC' & out$PLAYER=='Kyle Dugger' & out$DATE=='10/22/2026 14:55:57')
stopifnot(length(valid_drop)==1L,out[['RVSD?']][valid_drop]=='')
stopifnot(identical(out,apply_saladj_transaction_exceptions(out,2026)))
stopifnot(identical(rows,apply_saladj_transaction_exceptions(rows,2025)))
unchanged <- setdiff(seq_len(nrow(rows)),changed)
stopifnot(identical(rows[unchanged,],out[unchanged,]))
cat('Three exact voids marked, original history retained, valid Dugger drop and all other rows untouched; idempotent and season-specific PASS\n')
