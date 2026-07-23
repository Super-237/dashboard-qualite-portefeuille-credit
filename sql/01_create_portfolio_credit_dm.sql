/*===============================================================================
  Projet      : Portfolio Power BI - Qualite du portefeuille de credit (EMF)
  Script      : 01_create_portfolio_credit_dm.sql
  Objet       : Creation du data mart PORTFOLIO_CREDIT_DM (schema en etoile)
  Source      : CoreBanking_EMF (core banking) - alimentation via SSIS
  Arrete      : 30/09/2024
  Instance    : SQL Server 2019 (instance locale)
  Auteur      : Arnold
  Note        : Schema cree AVANT les packages SSIS (les destinations OLE DB
                doivent exister pour mapper les colonnes au design).
                Aucune donnee personnelle (PII) ne sera chargee ici :
                  - gestionnaires anonymises (LIBELLE_GEST = 'GEST-XXX')
                  - clients sans nom (DIM_CLIENT : cle de substitution CLIENT_ID)
===============================================================================*/

/*--------------------------------------------------------------------------
  1. Base de donnees
--------------------------------------------------------------------------*/
IF DB_ID('PORTFOLIO_CREDIT_DM') IS NULL
BEGIN
    CREATE DATABASE PORTFOLIO_CREDIT_DM;
END
GO

USE PORTFOLIO_CREDIT_DM;
GO

/*--------------------------------------------------------------------------
  2. Nettoyage (idempotent) - on supprime les faits avant les dimensions
     a cause des cles etrangeres.
--------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.FACT_DECAISSEMENT','U') IS NOT NULL DROP TABLE dbo.FACT_DECAISSEMENT;
IF OBJECT_ID('dbo.FACT_ECHEANCE','U')   IS NOT NULL DROP TABLE dbo.FACT_ECHEANCE;
IF OBJECT_ID('dbo.FACT_PRET','U')       IS NOT NULL DROP TABLE dbo.FACT_PRET;
IF OBJECT_ID('dbo.DIM_ARRETE','U')      IS NOT NULL DROP TABLE dbo.DIM_ARRETE;
IF OBJECT_ID('dbo.DIM_CLIENT','U')      IS NOT NULL DROP TABLE dbo.DIM_CLIENT;
IF OBJECT_ID('dbo.DIM_CLASSE_RETARD','U') IS NOT NULL DROP TABLE dbo.DIM_CLASSE_RETARD;
IF OBJECT_ID('dbo.DIM_PRODUIT','U')     IS NOT NULL DROP TABLE dbo.DIM_PRODUIT;
IF OBJECT_ID('dbo.DIM_GESTIONNAIRE','U') IS NOT NULL DROP TABLE dbo.DIM_GESTIONNAIRE;
IF OBJECT_ID('dbo.DIM_AGENCE','U')      IS NOT NULL DROP TABLE dbo.DIM_AGENCE;
IF OBJECT_ID('dbo.DIM_CALENDRIER','U')  IS NOT NULL DROP TABLE dbo.DIM_CALENDRIER;
GO

/*--------------------------------------------------------------------------
  3. Dimensions
--------------------------------------------------------------------------*/

-- 3.1 Calendrier (une ligne par jour ; DATE_ID au format AAAAMMJJ)
CREATE TABLE dbo.DIM_CALENDRIER (
    DATE_ID      INT          NOT NULL,   -- ex : 20240930
    DATE_JOUR    DATE         NOT NULL,
    ANNEE        SMALLINT     NOT NULL,
    TRIMESTRE    TINYINT      NOT NULL,
    MOIS         TINYINT      NOT NULL,
    NOM_MOIS     VARCHAR(15)  NOT NULL,
    ANNEE_MOIS   CHAR(7)      NOT NULL,   -- ex : 2024-09
    JOUR         TINYINT      NOT NULL,
    CONSTRAINT PK_DIM_CALENDRIER PRIMARY KEY (DATE_ID)
);
GO

-- 3.2 Agence
CREATE TABLE dbo.DIM_AGENCE (
    COD_AGENCE   CHAR(3)      NOT NULL,
    NOM_AGENCE   VARCHAR(100) NULL,
    VILLE        VARCHAR(40)  NULL,
    CONSTRAINT PK_DIM_AGENCE PRIMARY KEY (COD_AGENCE)
);
GO

-- 3.3 Gestionnaire (anonymise : pas de NOM/PRENOM, libelle neutre)
CREATE TABLE dbo.DIM_GESTIONNAIRE (
    GEST_ID      INT          IDENTITY(1,1) NOT NULL,
    COD_GEST     CHAR(6)      NOT NULL,   -- cle metier (code interne, non nominatif)
    LIBELLE_GEST VARCHAR(20)  NOT NULL,   -- ex : GEST-001
    COD_AGENCE   CHAR(3)      NULL,
    STATUT       VARCHAR(10)  NULL,       -- Actif / Parti (selon DATE_DEPART)
    TYPE_GEST    VARCHAR(15)  NULL,       -- Commercial / Recouvrement (regle metier declaree)
    CONSTRAINT PK_DIM_GESTIONNAIRE PRIMARY KEY (GEST_ID),
    CONSTRAINT UQ_DIM_GESTIONNAIRE_COD UNIQUE (COD_GEST),
    CONSTRAINT FK_GEST_AGENCE FOREIGN KEY (COD_AGENCE)
        REFERENCES dbo.DIM_AGENCE (COD_AGENCE)
);
GO

-- 3.4 Produit de credit
CREATE TABLE dbo.DIM_PRODUIT (
    COD_PRDT_CRD CHAR(3)      NOT NULL,
    NOM_PRODUIT  VARCHAR(60)  NULL,
    SEGMENT      VARCHAR(10)  NULL,       -- MICRO / MESO / MACRO (derive)
    CONSTRAINT PK_DIM_PRODUIT PRIMARY KEY (COD_PRDT_CRD)
);
GO

-- 3.5 Classe de retard (table de reference figee)
CREATE TABLE dbo.DIM_CLASSE_RETARD (
    CLASSE_ID    TINYINT      NOT NULL,
    LIBELLE      VARCHAR(20)  NOT NULL,
    ORDRE        TINYINT      NOT NULL,
    EST_PAR30    BIT          NOT NULL,   -- retard > 30 j
    EST_PAR90    BIT          NOT NULL,   -- retard > 90 j
    EST_PAR120   BIT          NOT NULL,   -- retard > 120 j
    CONSTRAINT PK_DIM_CLASSE_RETARD PRIMARY KEY (CLASSE_ID)
);
GO

-- Alimentation directe de la dimension de reference (5 classes)
INSERT INTO dbo.DIM_CLASSE_RETARD (CLASSE_ID, LIBELLE, ORDRE, EST_PAR30, EST_PAR90, EST_PAR120)
VALUES
    (1, 'A jour',    1, 0, 0, 0),
    (2, '1-30 j',    2, 0, 0, 0),
    (3, '31-90 j',   3, 1, 0, 0),
    (4, '91-120 j',  4, 1, 1, 0),
    (5, '>120 j',    5, 1, 1, 1);
GO

-- 3.6 Client (anonymise : cle de substitution, aucun nom)
CREATE TABLE dbo.DIM_CLIENT (
    CLIENT_ID      INT          IDENTITY(1,1) NOT NULL,
    COD_ADH        VARCHAR(10)  NOT NULL,   -- cle metier interne (non nominative)
    NATURE         VARCHAR(15)  NULL,       -- Individu / Entreprise / Groupe
    GENRE          VARCHAR(15)  NULL,       -- Femme / Homme / Entreprise / Groupe
    DATE_ADHESION  DATE         NULL,
    ANNEE_ADHESION SMALLINT     NULL,
    CONSTRAINT PK_DIM_CLIENT PRIMARY KEY (CLIENT_ID),
    CONSTRAINT UQ_DIM_CLIENT_COD UNIQUE (COD_ADH)
);
GO

-- 3.7 Arrete (dates de photo du portefeuille pour le snapshot periodique)
CREATE TABLE dbo.DIM_ARRETE (
    ARRETE_ID    INT          NOT NULL,   -- AAAAMMJJ (ex : 20240930)
    DATE_ARRETE  DATE         NOT NULL,
    LIBELLE      VARCHAR(20)  NOT NULL,   -- ex : Au 30/09/2024
    ANNEE        SMALLINT     NOT NULL,
    CONSTRAINT PK_DIM_ARRETE PRIMARY KEY (ARRETE_ID)
);
GO

INSERT INTO dbo.DIM_ARRETE (ARRETE_ID, DATE_ARRETE, LIBELLE, ANNEE)
VALUES
    (20220930, '2022-09-30', 'Au 30/09/2022', 2022),
    (20230930, '2023-09-30', 'Au 30/09/2023', 2023),
    (20240930, '2024-09-30', 'Au 30/09/2024', 2024);
GO

/*--------------------------------------------------------------------------
  4. Tables de faits
--------------------------------------------------------------------------*/

-- 4.1 FACT_PRET : grain = 1 ligne par pret DC, photo au 30/09/2024
--     Sert a l'encours, au PAR (30/90/120), au vintage, aux ventilations.
CREATE TABLE dbo.FACT_PRET (
    ARRETE_ID      INT          NOT NULL,   -- date de la photo (snapshot periodique)
    NUM_DOSSIER    VARCHAR(15)  NOT NULL,
    DATE_EFFET_ID  INT          NULL,
    COD_AGENCE     CHAR(3)      NULL,
    GEST_ID        INT          NULL,
    COD_PRDT_CRD   CHAR(3)      NULL,
    CLASSE_ID      TINYINT      NULL,
    CLIENT_ID      INT          NULL,     -- FK vers DIM_CLIENT (client anonymise)
    MONTANT_PRET   MONEY        NULL,
    ENCOURS        MONEY        NULL,
    RETARD_JOURS   INT          NULL,
    CONSTRAINT PK_FACT_PRET PRIMARY KEY (ARRETE_ID, NUM_DOSSIER),
    CONSTRAINT FK_FP_ARRETE FOREIGN KEY (ARRETE_ID)     REFERENCES dbo.DIM_ARRETE (ARRETE_ID),
    CONSTRAINT FK_FP_CAL    FOREIGN KEY (DATE_EFFET_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FP_AGENCE FOREIGN KEY (COD_AGENCE)    REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FP_GEST   FOREIGN KEY (GEST_ID)       REFERENCES dbo.DIM_GESTIONNAIRE (GEST_ID),
    CONSTRAINT FK_FP_PRDT   FOREIGN KEY (COD_PRDT_CRD)  REFERENCES dbo.DIM_PRODUIT (COD_PRDT_CRD),
    CONSTRAINT FK_FP_CLASSE FOREIGN KEY (CLASSE_ID)     REFERENCES dbo.DIM_CLASSE_RETARD (CLASSE_ID),
    CONSTRAINT FK_FP_CLIENT FOREIGN KEY (CLIENT_ID)     REFERENCES dbo.DIM_CLIENT (CLIENT_ID)
);
GO

-- 4.2 FACT_ECHEANCE : grain = 1 ligne par echeance
--     Perimetre = prets DC + SD + PE, echeances de 2022-01 a 2024-09.
--     Sert au taux de remboursement (encaisse / du) mensuel et cumule.
CREATE TABLE dbo.FACT_ECHEANCE (
    ECHEANCE_ID      BIGINT      IDENTITY(1,1) NOT NULL,
    NUM_DOSSIER      VARCHAR(15) NOT NULL,
    DATE_ECHEANCE_ID INT         NULL,
    COD_AGENCE       CHAR(3)     NULL,
    GEST_ID          INT         NULL,
    COD_PRDT_CRD     CHAR(3)     NULL,
    CAPITAL_DU       MONEY       NULL,
    CAPITAL_ENCAISSE MONEY       NULL,
    CONSTRAINT PK_FACT_ECHEANCE PRIMARY KEY (ECHEANCE_ID),
    CONSTRAINT FK_FE_CAL    FOREIGN KEY (DATE_ECHEANCE_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FE_AGENCE FOREIGN KEY (COD_AGENCE)       REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FE_GEST   FOREIGN KEY (GEST_ID)          REFERENCES dbo.DIM_GESTIONNAIRE (GEST_ID),
    CONSTRAINT FK_FE_PRDT   FOREIGN KEY (COD_PRDT_CRD)     REFERENCES dbo.DIM_PRODUIT (COD_PRDT_CRD)
);
GO

-- 4.3 FACT_DECAISSEMENT : grain = 1 ligne par credit MIS EN PLACE (flux).
--     Mesure la PRODUCTION (l'action du gestionnaire), pas le stock herite.
--     Perimetre : credits decaisses entre le 1er janvier et le 30 septembre de
--     chaque exercice (2022, 2023, 2024), pour des fenetres comparables.
--     Statut ND exclu : ces dossiers n'ont jamais ete decaisses.
CREATE TABLE dbo.FACT_DECAISSEMENT (
    NUM_DOSSIER      VARCHAR(15) NOT NULL,
    ARRETE_ID        INT         NOT NULL,   -- exercice de rattachement (jan -> sept)
    DATE_EFFET_ID    INT         NULL,
    COD_AGENCE       CHAR(3)     NULL,
    GEST_ID          INT         NULL,
    COD_PRDT_CRD     CHAR(3)     NULL,
    CLIENT_ID        INT         NULL,
    MONTANT_DECAISSE MONEY       NULL,
    ETAT_FINAL       VARCHAR(2)  NULL,       -- DC / SD / PE : le sort du credit
    EST_PERTE        BIT         NULL,       -- 1 si passe en perte
    CONSTRAINT PK_FACT_DECAISSEMENT PRIMARY KEY (NUM_DOSSIER),
    CONSTRAINT FK_FD_ARRETE FOREIGN KEY (ARRETE_ID)     REFERENCES dbo.DIM_ARRETE (ARRETE_ID),
    CONSTRAINT FK_FD_CAL    FOREIGN KEY (DATE_EFFET_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FD_AGENCE FOREIGN KEY (COD_AGENCE)    REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FD_GEST   FOREIGN KEY (GEST_ID)       REFERENCES dbo.DIM_GESTIONNAIRE (GEST_ID),
    CONSTRAINT FK_FD_PRDT   FOREIGN KEY (COD_PRDT_CRD)  REFERENCES dbo.DIM_PRODUIT (COD_PRDT_CRD),
    CONSTRAINT FK_FD_CLIENT FOREIGN KEY (CLIENT_ID)     REFERENCES dbo.DIM_CLIENT (CLIENT_ID)
);
GO

PRINT 'Data mart PORTFOLIO_CREDIT_DM cree : 6 dimensions + 3 faits.';
GO
