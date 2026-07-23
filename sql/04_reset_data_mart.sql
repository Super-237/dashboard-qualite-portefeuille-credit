/*===============================================================================
  Projet : Portfolio Power BI - Qualite du portefeuille de credit (EMF)
  Script : 04_reset_data_mart.sql
  Objet  : Vidage (reset) des tables pour rendre les chargements idempotents.
  Regle  : on vide les FAITS avant les DIMENSIONS (cles etrangeres).
           DIM_CLASSE_RETARD n'est PAS videe : elle est alimentee par le DDL (01),
           pas par les packages SSIS.
  Usage  : - Bloc A -> Execute SQL Task EN TETE du Package 1 (dimensions),
                        connexion PORTFOLIO_CREDIT_DM. Vide tout le data mart.
           - Bloc B -> Execute SQL Task EN TETE du Package 2 (faits),
                        connexion PORTFOLIO_CREDIT_DM. Vide seulement les faits.
===============================================================================*/


/*-------------------------------------------------------------------------------
  A. RESET COMPLET  (en tete du Package 1 - dimensions)
-------------------------------------------------------------------------------*/
USE PORTFOLIO_CREDIT_DM;

-- 1) Les faits d'abord (non referencees -> TRUNCATE possible, remet l'identite a 0)
TRUNCATE TABLE dbo.FACT_DECAISSEMENT;
TRUNCATE TABLE dbo.FACT_ECHEANCE;
TRUNCATE TABLE dbo.FACT_PRET;

-- 2) Les dimensions ensuite (referencees par FK -> DELETE, dans l'ordre des dependances)
DELETE FROM dbo.DIM_GESTIONNAIRE;   -- enfant de DIM_AGENCE
DELETE FROM dbo.DIM_CLIENT;
DELETE FROM dbo.DIM_PRODUIT;
DELETE FROM dbo.DIM_AGENCE;
DELETE FROM dbo.DIM_CALENDRIER;

-- 3) Reseed des identites des dimensions (DELETE ne remet pas le compteur a 0)
DBCC CHECKIDENT ('dbo.DIM_GESTIONNAIRE', RESEED, 0);
DBCC CHECKIDENT ('dbo.DIM_CLIENT',       RESEED, 0);


/*-------------------------------------------------------------------------------
  B. RESET DES FAITS UNIQUEMENT  (en tete du Package 2 - faits)
     Permet de rejouer le package des faits sans toucher aux dimensions.
-------------------------------------------------------------------------------*/
USE PORTFOLIO_CREDIT_DM;

TRUNCATE TABLE dbo.FACT_DECAISSEMENT;
TRUNCATE TABLE dbo.FACT_ECHEANCE;
TRUNCATE TABLE dbo.FACT_PRET;
