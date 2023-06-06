===================================
Workflow Overview
===================================

These documents describe an standardized Nextflow workflow for processing DIA mass spectrometry
data to quantify peptides and proteins. The workflow is described in the following paper: 

**Chromatogram libraries improve peptide detection and quantification by data independent acquisition mass spectrometry.**
Searle BC, Pino LK, Egertson JD, Ting YS, Lawrence RT, MacLean BX, Villén J, MacCoss MJ. *Nat Commun.* 2018 Dec 3;9(1):5128. 
(https://pubmed.ncbi.nlm.nih.gov/30510204/)

The workflow is summarized graphically as:

.. figure:: /_static/workflow_figure.png
   :class: with-border

   An overview of the computational pipeline implemented by this workflow. (A) the optional
   generation of a chromatogram library that can be fed into part (B) for peptide and
   protein quantification using DIA. If part (A) is not run, a user-supplied spectral library
   or chromatogram library may be used for quantification in part (B). 



Generally, what is this? Why does this exist. Why nextflow.

What computational workflows are supported.
    straight enc to skyline
    chromatogram generation
    etc

What programs are being run.

