source("load_packages.R")

library("WGCNA")
library("sva")

#### Hard coding for specific experiments


SAMPLE_NAMES <- c("C57", "Ola") %>%
  outer(c("P31", "P76"), str_c, sep="_") %>% 
  as.vector() %>%
  outer(c("1", "2", "3"), str_c, sep="_") %>%
  t %>%
  as.vector

SAMPLE_DATA <- data.frame(
  sample_name=SAMPLE_NAMES,
  condition1=rep(c('C57', 'Ola', 'C57', 'Ola'), each = 3),
  condition2=rep(c('P31', 'P76'), each = 6),
  row.names=SAMPLE_NAMES
)

SAMPLE_DATA %<>% mutate( 
  condition1_int = as.integer(condition1 == "Ola"),
  condition2_int = as.integer(condition2 == "P76"))

genes_tsv <- str_c("data/", "mouse", "_ensembl_91/genes.tsv") # Can vary with species and Ensembl versions

##### FUNCTIONS

RESULTS_DIR <- "results/wgcna/"

read_counts <- function(sample) {
  counts_file_name <- str_c("results/read_counts/", sample, ".counts")
  counts_file_name %>% read_tsv(col_names=c("gene", str_c(sample)))
}

remove_gene_column <- function(count_data) {
count_data %>% tibble::column_to_rownames(var="gene")
}

get_deseq2_dataset <- function(count_data, sample_data, filter_low_counts=TRUE, 
                               design_formula=~condition1) {
  
  dds <- DESeqDataSetFromMatrix(countData=count_data, colData=sample_data, design=design_formula)
  
  if (filter_low_counts) {
    dds <- dds[rowSums(counts(dds)) > 1, ]
  }
  
  dds %>% DESeq
}

plot_heat_map <- function(expression_data, sample_data) {
  distsRL <- expression_data %>% t %>% dist

  mat <- distsRL %>% as.matrix()
  rownames(mat) <- colnames(mat) <- sample_data %>% row.names

  hc <- distsRL %>% hclust
  hmcol <- colorRampPalette(brewer.pal(9, "GnBu"))(100)
  heatmap.2(mat, Rowv=hc %>% as.dendrogram, 
            symm=TRUE, trace="none",
            col = hmcol %>% rev, margin=c(10, 10))
}

plot_soft_threshold_graphs <- function(expression_data) {
  powers = c(c(1:10), seq(from = 12, to=30, by=2))
  
  sft <- expression_data %>% t %>% 
    pickSoftThreshold(powerVector=powers, networkType="signed", blockSize=100000, verbose=5)
  
  signed_r2 <- -sign(sft$fitIndices[,3])*sft$fitIndices[,2]
  mean_connectivity <- sft$fitIndices[,5]
  
  plot(powers, signed_r2,
       xlab="Soft Threshold (power)",ylab="Scale Free Topology Model Fit,signed R^2",type="n",
       main = paste("Scale independence"));
  text(powers, signed_r2,labels=powers,col="red");
  abline(h=0.90,col="red")
  
  plot(powers, mean_connectivity,
       xlab="Soft Threshold (power)",ylab="Mean Connectivity", type="n",
       main = paste("Mean connectivity"))
  text(powers, mean_connectivity, labels=powers, col="red")  
}

perform_wgcna <- function(expression_data, power=16) {
  MAX_BLOCK_SIZE <- 46340 - 1 # Limit set by WGCNA - sqrt(2^31)
  
  net = expression_data %>% t %>% 
    blockwiseModules(power = power, networkType = "signed", 
                     TOMType = "signed", minModuleSize = 30,
                     reassignThreshold = 0, mergeCutHeight = 0.25,
                     numericLabels = TRUE, pamRespectsDendro = FALSE,
                     maxBlockSize = MAX_BLOCK_SIZE, verbose = 5)
  
  print(table(net$colors))
  
  mergedColors = labels2colors(net$colors)
  plotDendroAndColors(net$dendrograms[[1]], mergedColors[net$blockGenes[[1]]],
                      "Module colors", dendroLabels = FALSE, hang = 0.03,
                      addGuide = TRUE, guideHang = 0.05)
  
  list(net$colors, orderMEs(net$MEs))
}

get_experimental_variables <- function() {
  SAMPLE_DATA %>% dplyr::select(condition1_int, condition2_int) 
}

get_eigengene_variable_correlations <- function(module_eigengenes) {
  exp_vars <- get_experimental_variables()
  eigengene_exp_vars_correlation <- module_eigengenes %>% WGCNA::cor(exp_vars, use='p')
  correlation_p_vals <- eigengene_exp_vars_correlation %>% corPvalueStudent(SAMPLE_DATA %>% nrow)
  
  list(eigengene_exp_vars_correlation, correlation_p_vals)
}

display_eigengene_variable_correlations <- function(
  eigengene_exp_vars_correlation, correlation_p_vals,
  write_to_file=FALSE) {
  
  textMatrix <- eigengene_exp_vars_correlation %>% 
    signif(2) %>% 
    paste(" (", correlation_p_vals %>% signif(1), ")", sep = "");
  
  dim(textMatrix) <- dim(eigengene_exp_vars_correlation)
  
  if (write_to_file) {
    png(filename=str_c(RESULTS_DIR, "eigengene_correlation.png"),
        width=800, height=800)
  }
  
  labeledHeatmap(Matrix = eigengene_exp_vars_correlation,
                 xLabels = get_experimental_variables() %>% names,
                 yLabels = names(module_eigengenes),
                 ySymbols = names(module_eigengenes),
                 colorLabels = FALSE, colors = blueWhiteRed(50),
                 textMatrix = textMatrix, 
                 setStdMargins = FALSE, zlim = c(-1,1),
                 main = paste("Eigengene-experimental variable relationships"))
  
  if (write_to_file) {
    dev.off()
  }
}

get_gene_eigengene_correlations <- function(expression_data, module_eigengenes) {
  gene_eigengene_correlations = expression_data %>% t %>% 
    cor(module_eigengenes, use = "p")
  
  correlation_p_vals = gene_eigengene_correlations %>% 
    corPvalueStudent(SAMPLE_DATA %>% nrow)
  
  gene_eigengene_correlations %<>% as.data.frame
  correlation_p_vals %<>% as.data.frame
  
  modNames <- module_eigengenes %>% names %>% substring(3)
  names(gene_eigengene_correlations) <- "MM" %>% paste(modNames, sep="")
  names(correlation_p_vals) <- "p.MM" %>% paste(modNames, sep="")
  
  list(gene_eigengene_correlations, correlation_p_vals)
}

get_gene_variable_correlations <- function(expression_data, variable, var_name) {
  variable %<>% as.data.frame
  names(variable) <- var_name
  
  correlations <- expression_data %>% t %>% cor(variable, use = "p")
  correlation_p_vals = corPvalueStudent(correlations, SAMPLE_DATA %>% nrow)
  
  correlations %<>% as.data.frame 
  correlation_p_vals %<>% as.data.frame
  
  names(correlations) <- paste("GC.", variable %>% names, sep="")
  names(correlation_p_vals) <- paste("p.GC.", variable %>% names, sep="")
  
  list(correlations, correlation_p_vals)
}

plot_gene_module_variable_correlations <- function(
  module, modules_to_genes, module_eigengenes, 
  gene_eigengene_correlations, gene_variable_correlations,
  var_name, write_to_file=FALSE) {
  
  mod_names <- module_eigengenes %>% names %>% substring(3)
  
  module_column <- module %>% match(mod_names)
  genes_in_module <- modules_to_genes==module
  
  if (write_to_file) {
    png(filename=str_c(RESULTS_DIR, "M", module, "_", var_name, "_correlation.png"),
        width=800, height=800)
  }
  
  verboseScatterplot(gene_eigengene_correlations[genes_in_module, module_column],
                     gene_variable_correlations[genes_in_module, 1],
                     xlab = paste("Module membership in module", module),
                     ylab = paste("Gene correlation for", var_name),
                     main = paste("Gene correlation vs. module membership\n"),
                     cex.main = 1.2, cex.lab = 1.2, cex.axis = 1.2, col = module + 1)
  
  if (write_to_file) {
    dev.off() 
  }
}

plot_module_eigengene_values <- function(module, module_eigengenes, write_to_file=FALSE) {
  plot_info <- module_eigengenes %>% cbind(SAMPLE_DATA %>% tibble::rownames_to_column(var="name"))
  
  if (write_to_file) {
    png(filename=str_c(RESULTS_DIR, "M", module, "_eigengene_values.png"),
        width=800, height=800)
  }
  
  p <- ggplot(data=plot_info, aes_string(x="condition1", y=str_c("ME", module))) + 
    geom_point()
  print(p)
  
  if (write_to_file) {
    dev.off() 
  }
}

get_genes_for_module <- function(module, modules_to_genes, gene_eigengene_correlations, gene_info) {
  column <- str_c("MM", module)
  
  gene_eigengene_correlations %>% 
    as.data.frame %>% 
    tibble::rownames_to_column(var="gene") %>% 
    inner_join(gene_info) %>%
    dplyr::select_("gene", "gene_name", "description", "chromosome", column) %>%
    extract(genes_in_module <- modules_to_genes==module,) %>%
    arrange_(paste0("desc(", column, ")"))
}

get_gene_info <- function(species = 'mouse') {
  read_tsv(genes_tsv,
    col_names = c("gene", "description", "chromosome", "gene_name", "entrez_id"),
    col_types = list(chromosome = col_character()))
}

get_significant_genes <- function(term, GOdata, gene_info) {
  genes_for_term <- GOdata %>% genesInTerm(term) %>% extract2(1)
  significant_genes <- GOdata %>% sigGenes
  significant_genes_for_term <- genes_for_term %>% intersect(significant_genes)
  
  gene_info %>% 
    filter(gene %in% significant_genes_for_term) %>% 
    dplyr::select(gene_name) %>% 
    extract2(1) %>% 
    paste(collapse=", ")
}

perform_go_analysis <- function(gene_universe, significant_genes, ontology="BP") {
  gene_list <- (gene_universe$gene %in% significant_genes$gene) %>% as.integer %>% factor
  names(gene_list) <- gene_universe$gene
  
  go_data <- new("topGOdata", ontology=ontology, allGenes=gene_list,
                 annot=annFUN.org, mapping="org.Mm.eg.db", ID="Ensembl")
  
  result_fisher <- go_data %>% runTest(algorithm="weight01", statistic="fisher")
  result_fisher %>% print
  
  go_results <- go_data %>% GenTable(weight_fisher=result_fisher, orderBy="weight_fisher", topNodes=150)
  
  go_results$Genes <- sapply(go_results[,c('GO.ID')], 
                             function(x) get_significant_genes(x, go_data, get_gene_info("mouse")))
  
  go_results
}

perform_go_analyses <- function(significant_genes, expressed_genes, file_prefix) {
  c("BP", "MF", "CC") %>% walk(
    function(x) {
      perform_go_analysis(expressed_genes, significant_genes, x) %>%
        write_csv(str_c(RESULTS_DIR, file_prefix, "_go_", x %>% tolower, ".csv"),na = "")
    }
  )
}

#####

get_dds <- function() {
  count_data <- SAMPLE_NAMES %>%
    map(read_counts) %>%
    purrr::reduce(inner_join) %>%
    remove_gene_column()
  
  get_deseq2_dataset(
    count_data, SAMPLE_DATA, design_formula=~1)
}

#####

# Use DESeq2 to calculate normalised counts
dds <- get_dds()

# Set a threshold to exclude lowly expressed genes
expressed_genes <- rowSums(counts(dds, norm=T)) > 100

# Perform variance stabilizing transformation on counts, so that they can be input to WGCNA
vst <- dds %>% varianceStabilizingTransformation

# Now exclude lowly-expressed genes
gene_expression <- (vst %>% assay)[expressed_genes, ]

# Plot graphs to help pick a soft-threshold power
gene_expression %>% plot_soft_threshold_graphs

# Perform WGCNA analysis
wgcna_network <- gene_expression %>% perform_wgcna(power = 20)
modules_to_genes <- wgcna_network[[1]]
module_eigengenes <- wgcna_network[[2]]



# Calculate correlations between module eigengenes and experimental variables
eigengene_variable_correlation_data <- get_eigengene_variable_correlations(module_eigengenes)
eigengene_variable_correlations <- eigengene_variable_correlation_data[[1]]
eigengene_variable_correlation_p_vals <- eigengene_variable_correlation_data[[2]]

display_eigengene_variable_correlations(
  eigengene_variable_correlations, eigengene_variable_correlation_p_vals,
  write_to_file=F)

# Calculate correlations between gene expression and module eigengenes
gene_eigengene_correlation_data <- get_gene_eigengene_correlations(
  gene_expression, module_eigengenes)

gene_eigengene_correlations <-gene_eigengene_correlation_data[[1]]

# Calculate correlations between gene expression and experimental variables
gene_condition1_correlation_data <- gene_expression %>% 
  get_gene_variable_correlations(SAMPLE_DATA$condition1_int, "condition1")
gene_condition1_correlations <- gene_condition1_correlation_data[[1]]

gene_condition2_correlation_data <- gene_expression %>% 
  get_gene_variable_correlations(SAMPLE_DATA$condition2_int, "condition2")
gene_condition2_correlations <- gene_condition2_correlation_data[[1]]

# Construct table of per-gene info for output
mod_numbers <- module_eigengenes %>% names %>% substring(3)

output <- NULL

for (module in seq(0, module_eigengenes %>% colnames %>% length - 1)) {
  genes_in_module <- modules_to_genes==module
  module_column <- str_c("MM", module)
  
  gecs_for_module <- gene_eigengene_correlations[genes_in_module, ] %>%
    dplyr::select_(module_column) %>%
    rename_("eigengene_cor" = module_column)
  
  if (is.null(output)) {
    output <- gecs_for_module 
  } else {
    output %<>% rbind(gecs_for_module) 
  }
}

output %<>% tibble::rownames_to_column(var="gene") %>%
  inner_join(gene_expression %>% 
               as.data.frame %>% 
               tibble::rownames_to_column(var="gene") %>%
               cbind(modules_to_genes) %>% 
               mutate(module=str_c(modules_to_genes)) %>% 
               dplyr::select(gene, module))

output %<>% 
  inner_join(gene_condition1_correlations %>% tibble::rownames_to_column(var="gene")) %>% 
  inner_join(gene_condition2_correlations %>% tibble::rownames_to_column(var="gene")) %>% 
  rename(condition1_cor=GC.condition1, condition2_cor=GC.condition2)

mouse_gene_info <- get_gene_info(species = "mouse")
output %<>% inner_join(mouse_gene_info) 

output %<>% 
  dplyr::select(gene, gene_name, description, chromosome, module, 
                eigengene_cor, condition1_cor, condition2_cor) %>% 
  write_csv(str_c(RESULTS_DIR, "genes_to_modules.csv"),na = "")

# For each module:
# (i)   Scatter plots of gene-variable correlations against gene-eigengene correlations
# (ii)  Plot of per-condition eigengene values 
# (iii) Perform GO analyses for genes in module

for (module in seq(0, module_eigengenes %>% colnames %>% length - 1)) {
    plot_gene_module_variable_correlations(
    module, modules_to_genes, module_eigengenes,
    gene_eigengene_correlations, gene_condition1_correlations,
    "condition1", write_to_file=TRUE) 
  
    plot_gene_module_variable_correlations(
    module, modules_to_genes, module_eigengenes,
    gene_eigengene_correlations, gene_condition2_correlations,
    "condition2", write_to_file=TRUE) 
  
  plot_module_eigengene_values(module, module_eigengenes, write_to_file=TRUE)
  
  get_genes_for_module(module, modules_to_genes, gene_eigengene_correlations, mouse_gene_info) %>% 
    perform_go_analyses(expressed_genes %>% as.data.frame %>% tibble::rownames_to_column(var="gene"), str_c("M", module))
}
