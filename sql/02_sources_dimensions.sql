/*===============================================================================
  Projet : Portfolio Power BI - Qualite du portefeuille de credit (EMF)
  Script : 02_sources_dimensions.sql
  Objet  : Requetes SOURCE pour le chargement des dimensions via SSIS.
  Usage  : - Bloc CALENDRIER  -> Execute SQL Task sur la connexion DESTINATION
                                  (PORTFOLIO_CREDIT_DM).
           - Blocs AGENCE / PRODUIT / GESTIONNAIRE -> a coller dans chaque
             OLE DB Source (mode "SQL command"), connexion SOURCE
             (CoreBanking_EMF).
===============================================================================*/


/*-------------------------------------------------------------------------------
  A. DIM_CALENDRIER  (Execute SQL Task, connexion = PORTFOLIO_CREDIT_DM)
     Genere un calendrier 2015-01-01 -> 2025-12-31. Idempotent.
-------------------------------------------------------------------------------*/
SET LANGUAGE French;

IF NOT EXISTS (SELECT 1 FROM dbo.DIM_CALENDRIER)
BEGIN
    ;WITH d AS (
        SELECT CAST('2015-01-01' AS date) AS dj
        UNION ALL
        SELECT DATEADD(day, 1, dj) FROM d WHERE dj < '2025-12-31'
    )
    INSERT INTO dbo.DIM_CALENDRIER
        (DATE_ID, DATE_JOUR, ANNEE, TRIMESTRE, MOIS, NOM_MOIS, ANNEE_MOIS, JOUR)
    SELECT
        CONVERT(int, CONVERT(char(8), dj, 112)) AS DATE_ID,   -- AAAAMMJJ
        dj,
        YEAR(dj),
        DATEPART(quarter, dj),
        MONTH(dj),
        DATENAME(month, dj),                                  -- mois en francais
        CONVERT(char(7), dj, 121),                            -- AAAA-MM
        DAY(dj)
    FROM d
    OPTION (MAXRECURSION 0);
END;


/*-------------------------------------------------------------------------------
  B. DIM_AGENCE  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_AGENCE, NOM_AGENCE, VILLE
     ANONYMISATION : noms d'agence reels (villes) remplaces par des libelles
     generiques declares, ville mise a NULL. Mapping fige (regle metier) pour
     rester stable d'un rechargement a l'autre.
-------------------------------------------------------------------------------*/
SELECT
    COD_AGENCE,
    CAST(
        CASE COD_AGENCE
            WHEN 'B01' THEN 'Agence 07'
            WHEN 'D01' THEN 'Agence 01'
            WHEN 'D03' THEN 'Agence 03'
            WHEN 'D04' THEN 'Agence 04'
            WHEN 'D05' THEN 'Agence 05'
            WHEN 'D06' THEN 'Agence 08'
            WHEN 'DG1' THEN 'Siege (DG)'
            WHEN 'G02' THEN 'Agence 02'
            WHEN 'O02' THEN 'Agence 09'
            WHEN 'Y01' THEN 'Agence 06'
            WHEN 'Y02' THEN 'Agence 10'
            ELSE COD_AGENCE
        END AS varchar(100)) AS NOM_AGENCE,
    CAST(NULL AS varchar(40)) AS VILLE
FROM dbo.AGENCE;


/*-------------------------------------------------------------------------------
  C. DIM_PRODUIT  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_PRDT_CRD, NOM_PRODUIT, SEGMENT
     SEGMENT derive du libelle (MICRO / MESO / MACRO).
-------------------------------------------------------------------------------*/
SELECT
    COD_PRDT_CRD,
    NOM_PRDT_CRD AS NOM_PRODUIT,
    CASE
        WHEN NOM_PRDT_CRD LIKE '%MICRO%' THEN 'MICRO'
        WHEN NOM_PRDT_CRD LIKE '%MESO%'  THEN 'MESO'
        WHEN NOM_PRDT_CRD LIKE '%MACRO%' THEN 'MACRO'
        ELSE 'AUTRE'
    END AS SEGMENT
FROM dbo.PRDT_CRD;


/*-------------------------------------------------------------------------------
  D. DIM_GESTIONNAIRE  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_GEST, LIBELLE_GEST, COD_AGENCE, STATUT, TYPE_GEST
     ANONYMISATION : on n'expose ni NOM ni PRENOM, juste un libelle neutre.
     COD_AGENCE force a NULL s'il n'existe pas dans AGENCE (securite cle etrangere).

     TYPE_GEST : REGLE METIER DECLAREE, non deduite des donnees.
       Les gestionnaires de recouvrement recoivent les credits deja degrades ;
       leur PAR avoisine 100 % PAR CONSTRUCTION et ne mesure pas une performance.
       Les separer evite de comparer des commerciaux a des recouvreurs.
       Aucun marqueur natif n'existe dans la base : ni ETAT_PRET/DECLAS (le
       declassement = passage en perte uniquement), ni CNT_AUTORISE (champ non
       renseigne), ni TRANS_CREDIT (qui trace les transferts de collecte).
       => La liste ci-dessous est maintenue a la main. AJOUTER ICI tout nouveau
          code de gestionnaire de recouvrement.
-------------------------------------------------------------------------------*/
SELECT
    g.COD_GEST,
    'GEST-' + RIGHT('000' + CAST(ROW_NUMBER() OVER (ORDER BY g.COD_GEST) AS varchar(3)), 3) AS LIBELLE_GEST,
    CASE WHEN g.COD_AGENCE IN (SELECT a.COD_AGENCE FROM dbo.AGENCE a)
         THEN g.COD_AGENCE ELSE NULL END AS COD_AGENCE,
    CASE WHEN g.DATE_DEPART IS NULL THEN 'Actif' ELSE 'Parti' END AS STATUT,
    CASE WHEN g.COD_GEST IN ('024Y01', '024D06')   -- <== liste des recouvreurs
         THEN 'Recouvrement' ELSE 'Commercial' END AS TYPE_GEST
FROM dbo.GESTIONNAIRE g;


/*-------------------------------------------------------------------------------
  E. DIM_CLIENT  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_ADH, NATURE, GENRE, DATE_ADHESION, ANNEE_ADHESION
     - Referentiel client = ADHERENT (on ignore T_ADHERENT).
     - Nature deduite de la presence dans INDIVIDU / ENTREPRISE / GROUPE.
       Clients absents des trois tables : ignores (WHERE final).
     - Genre : Femme/Homme (SEXE des individus), sinon Entreprise / Groupe.
     - ANONYMISATION : aucun nom expose ; COD_ADH = code interne (cle de lookup).
-------------------------------------------------------------------------------*/
-- NB : INDIVIDU peut contenir plusieurs fiches pour un meme COD_ADH (doublons).
--      On dedoublonne chaque table de detail (une ligne par COD_ADH) AVANT la
--      jointure, pour garantir une seule ligne par client (sinon violation de
--      la contrainte UNIQUE sur DIM_CLIENT.COD_ADH).
SELECT
    a.COD_ADH,
    CASE WHEN i.COD_ADH IS NOT NULL THEN 'Individu'
         WHEN e.COD_ADH IS NOT NULL THEN 'Entreprise'
         WHEN g.COD_ADH IS NOT NULL THEN 'Groupe' END AS NATURE,
    CASE WHEN i.COD_ADH IS NOT NULL THEN
              CASE WHEN i.SEXE = 'F' THEN 'Femme'
                   WHEN i.SEXE = 'M' THEN 'Homme'
                   ELSE 'Indetermine' END
         WHEN e.COD_ADH IS NOT NULL THEN 'Entreprise'
         WHEN g.COD_ADH IS NOT NULL THEN 'Groupe' END AS GENRE,
    CONVERT(date, a.DATE_INSCRIP) AS DATE_ADHESION,
    YEAR(a.DATE_INSCRIP)          AS ANNEE_ADHESION
FROM dbo.ADHERENT a
LEFT JOIN (SELECT COD_ADH, MIN(SEXE) AS SEXE FROM dbo.INDIVIDU GROUP BY COD_ADH) i
       ON i.COD_ADH = a.COD_ADH
LEFT JOIN (SELECT DISTINCT COD_ADH FROM dbo.ENTREPRISE) e
       ON e.COD_ADH = a.COD_ADH
LEFT JOIN (SELECT DISTINCT COD_ADH FROM dbo.GROUPE) g
       ON g.COD_ADH = a.COD_ADH
WHERE i.COD_ADH IS NOT NULL
   OR e.COD_ADH IS NOT NULL
   OR g.COD_ADH IS NOT NULL;
