namespace_packages <- function(files) {
  sort(unique(unlist(lapply(files,function(path) {
    tokens <- getParseData(parse(path,keep.source=TRUE))
    tokens$text[tokens$token=="SYMBOL_PACKAGE"]
  }),use.names=FALSE)))
}
undeclared_packages <- function(packages,description) {
  imports <- trimws(gsub("\\s*\\([^)]*\\)","",
    unlist(strsplit(description[1,"Imports"],",",fixed=TRUE))))
  base <- rownames(installed.packages(priority="base"))
  setdiff(packages,c(imports,base))
}

# Parse R syntax rather than matching package-like text inside strings/comments.
fixture <- tempfile(fileext=".R")
writeLines(c('jsonlite::toJSON(list())', '# absentPackage::not_code()',
  'text <- "anotherAbsentPackage::not_code()"'),fixture)
stopifnot(identical(namespace_packages(fixture),"jsonlite"))
unlink(fixture)
description <- read.dcf("DESCRIPTION")
stopifnot(length(undeclared_packages("digest",matrix("jsonlite",nrow=1,
  dimnames=list(NULL,"Imports"))))==1L)

files <- unlist(lapply(c("R","scripts","tests"),list.files,
  pattern="[.]R$",recursive=TRUE,full.names=TRUE),use.names=FALSE)
missing <- undeclared_packages(namespace_packages(files),description)
if(length(missing)) stop("R namespace dependencies missing from DESCRIPTION Imports: ",
  paste(missing,collapse=", "))
message("PASS: parsed R namespace dependencies are declared; comments/strings excluded; missing digest is rejected.")
