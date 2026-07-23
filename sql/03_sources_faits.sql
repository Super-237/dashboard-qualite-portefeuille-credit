/*===============================================================================
  Projet : Portfolio Power BI - Qualite du portefeuille de credit (EMF)
  Script : 03_sources_faits.sql
  Objet  : Requetes SOURCE pour le chargement des tables de faits via SSIS.
  Arretes: FACT_PRET = snapshot periodique au 30/09/2022, 2023 et 2024.
           FACT_ECHEANCE = flux d'echeances (2021 -> 09/2024), non snapshote.
  Usage  : Blocs F et G a coller dans les OLE DB Source (connexion SOURCE
           CoreBanking_EMF). Cles de substitution (GEST_ID, CLIENT_ID) resolues
           par des Lookups SSIS, pas dans le SQL.

  Regles metier :
   - Vivant a une date A = decaisse avant A et non solde a A
     (DATE_EFFET <= A ET (DATE_SOLDE IS NULL OU DATE_SOLDE > A)), statut DC ou SD.
     Les PE (passes en perte) sont exclus (analyse des pertes = V2).
   - Encours(A) = SUM(TABAMOR.CAPITAL) - SUM(REMBOURS.CAPITAL_REMB, DATE_REMB<=A)
   - Retard(A) = jours entre la plus ancienne echeance echue impayee et A
   - Classes : 1=A jour, 2=1-30j, 3=31-90j, 4=91-120j, 5=>120j
===============================================================================*/


/*-------------------------------------------------------------------------------
  F. FACT_PRET  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : 1 ligne par (arrete, pret vivant). Snapshot periodique 3 dates.
     Sortie : ARRETE_ID, NUM_DOSSIER, DATE_EFFET_ID, COD_AGENCE, COD_GEST,
              COD_PRDT_CRD, COD_ADH, CLASSE_ID, MONTANT_PRET, ENCOURS, RETARD_JOURS
     -> Lookups SSIS : COD_GEST -> GEST_ID ; COD_ADH -> CLIENT_ID
-------------------------------------------------------------------------------*/
WITH arretes AS (
    SELECT CAST('2022-09-30' AS date) AS A
    UNION ALL SELECT CAST('2023-09-30' AS date)
    UNION ALL SELECT CAST('2024-09-30' AS date)
),
base AS (   -- prets vivants a chaque arrete (DC ou SD, PE exclus)
    SELECT ar.A, p.NUM_DOSSIER, p.REF_DEMANDE, p.DATE_EFFET, p.MONTANT_PRET
    FROM dbo.PRETS p
    CROSS JOIN arretes ar
    WHERE p.ETAT_PRET IN ('DC', 'SD')
      AND p.DATE_EFFET <= ar.A
      AND (p.DATE_SOLDE IS NULL OR p.DATE_SOLDE > ar.A)
),
tot_sched AS (   -- capital total prevu par pret (independant de l'arrete)
    SELECT NUM_DOSSIER, SUM(CAPITAL) AS cap_prevu_total
    FROM dbo.TABAMOR GROUP BY NUM_DOSSIER
),
paid_to_A AS (   -- capital rembourse par pret jusqu'a chaque arrete
    SELECT b.A, b.NUM_DOSSIER, SUM(r.CAPITAL_REMB) AS cap_paye
    FROM base b
    JOIN dbo.REMBOURS r ON r.NUM_DOSSIER = b.NUM_DOSSIER AND r.DATE_REMB <= b.A
    GROUP BY b.A, b.NUM_DOSSIER
),
ech AS (   -- capital prevu par echeance echue (<= arrete)
    SELECT b.A, t.NUM_DOSSIER, t.DATE_ECHEANCE, SUM(t.CAPITAL) AS cap_prevu
    FROM base b
    JOIN dbo.TABAMOR t ON t.NUM_DOSSIER = b.NUM_DOSSIER AND t.DATE_ECHEANCE <= b.A
    GROUP BY b.A, t.NUM_DOSSIER, t.DATE_ECHEANCE
),
pay AS (   -- capital paye par echeance jusqu'a l'arrete
    SELECT b.A, r.NUM_DOSSIER, r.DATE_ECHEANCE, SUM(r.CAPITAL_REMB) AS cap_paye
    FROM base b
    JOIN dbo.REMBOURS r ON r.NUM_DOSSIER = b.NUM_DOSSIER AND r.DATE_REMB <= b.A
    GROUP BY b.A, r.NUM_DOSSIER, r.DATE_ECHEANCE
),
solde_ech AS (
    SELECT e.A, e.NUM_DOSSIER, e.DATE_ECHEANCE,
           e.cap_prevu - ISNULL(p.cap_paye, 0) AS solde
    FROM ech e
    LEFT JOIN pay p ON p.A = e.A AND p.NUM_DOSSIER = e.NUM_DOSSIER
                   AND p.DATE_ECHEANCE = e.DATE_ECHEANCE
),
retard AS (
    SELECT A, NUM_DOSSIER, MIN(DATE_ECHEANCE) AS plus_ancienne
    FROM solde_ech WHERE solde > 1 GROUP BY A, NUM_DOSSIER
),
ddem AS (
    SELECT REF_DEMANDE, COD_GEST, COD_PRDT_CRD, COD_ADH,
           ROW_NUMBER() OVER (PARTITION BY REF_DEMANDE ORDER BY DATE_VALIDATION DESC) AS rn
    FROM dbo.DEMPRET
)
SELECT
    CONVERT(int, CONVERT(char(8), b.A, 112)) AS ARRETE_ID,
    b.NUM_DOSSIER,
    CONVERT(int, CONVERT(char(8), b.DATE_EFFET, 112)) AS DATE_EFFET_ID,
    LEFT(b.NUM_DOSSIER, 3) AS COD_AGENCE,
    d.COD_GEST,
    d.COD_PRDT_CRD,
    d.COD_ADH,
    CASE WHEN r.plus_ancienne IS NULL                       THEN 1
         WHEN DATEDIFF(day, r.plus_ancienne, b.A) <= 0       THEN 1
         WHEN DATEDIFF(day, r.plus_ancienne, b.A) <= 30      THEN 2
         WHEN DATEDIFF(day, r.plus_ancienne, b.A) <= 90      THEN 3
         WHEN DATEDIFF(day, r.plus_ancienne, b.A) <= 120     THEN 4
         ELSE 5 END AS CLASSE_ID,
    b.MONTANT_PRET,
    ISNULL(ts.cap_prevu_total, 0) - ISNULL(pa.cap_paye, 0) AS ENCOURS,
    CASE WHEN r.plus_ancienne IS NULL THEN 0
         ELSE DATEDIFF(day, r.plus_ancienne, b.A) END AS RETARD_JOURS
FROM base b
LEFT JOIN tot_sched ts ON ts.NUM_DOSSIER = b.NUM_DOSSIER
LEFT JOIN paid_to_A pa ON pa.A = b.A AND pa.NUM_DOSSIER = b.NUM_DOSSIER
LEFT JOIN retard r     ON r.A = b.A AND r.NUM_DOSSIER = b.NUM_DOSSIER
LEFT JOIN ddem d       ON d.REF_DEMANDE = b.REF_DEMANDE AND d.rn = 1;


/*-------------------------------------------------------------------------------
  G. FACT_ECHEANCE  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : 1 ligne par echeance. Perimetre : prets DC + SD + PE.
     Periode : echeances du 01/01/2021 au 30/09/2024.
     Sortie : NUM_DOSSIER, DATE_ECHEANCE_ID, COD_AGENCE, COD_GEST, COD_PRDT_CRD,
              CAPITAL_DU, CAPITAL_ENCAISSE
     -> Lookup SSIS : COD_GEST -> GEST_ID
-------------------------------------------------------------------------------*/
DECLARE @A2 date = '2024-09-30';
DECLARE @DEBUT date = '2021-01-01';

WITH scope AS (
    SELECT NUM_DOSSIER, REF_DEMANDE
    FROM dbo.PRETS WHERE ETAT_PRET IN ('DC', 'SD', 'PE')
),
ech AS (
    SELECT t.NUM_DOSSIER, t.DATE_ECHEANCE, SUM(t.CAPITAL) AS cap_du
    FROM dbo.TABAMOR t JOIN scope s ON s.NUM_DOSSIER = t.NUM_DOSSIER
    WHERE t.DATE_ECHEANCE >= @DEBUT AND t.DATE_ECHEANCE <= @A2
    GROUP BY t.NUM_DOSSIER, t.DATE_ECHEANCE
),
pay AS (
    SELECT r.NUM_DOSSIER, r.DATE_ECHEANCE, SUM(r.CAPITAL_REMB) AS cap_enc
    FROM dbo.REMBOURS r JOIN scope s ON s.NUM_DOSSIER = r.NUM_DOSSIER
    WHERE r.DATE_REMB <= @A2
    GROUP BY r.NUM_DOSSIER, r.DATE_ECHEANCE
),
ddem AS (
    SELECT REF_DEMANDE, COD_GEST, COD_PRDT_CRD,
           ROW_NUMBER() OVER (PARTITION BY REF_DEMANDE ORDER BY DATE_VALIDATION DESC) AS rn
    FROM dbo.DEMPRET
)
SELECT
    e.NUM_DOSSIER,
    CONVERT(int, CONVERT(char(8), e.DATE_ECHEANCE, 112)) AS DATE_ECHEANCE_ID,
    LEFT(e.NUM_DOSSIER, 3) AS COD_AGENCE,
    d.COD_GEST,
    d.COD_PRDT_CRD,
    e.cap_du AS CAPITAL_DU,
    ISNULL(p.cap_enc, 0) AS CAPITAL_ENCAISSE
FROM ech e
LEFT JOIN pay p   ON p.NUM_DOSSIER = e.NUM_DOSSIER AND p.DATE_ECHEANCE = e.DATE_ECHEANCE
LEFT JOIN scope s ON s.NUM_DOSSIER = e.NUM_DOSSIER
LEFT JOIN ddem d  ON d.REF_DEMANDE = s.REF_DEMANDE AND d.rn = 1;


/*-------------------------------------------------------------------------------
  H. FACT_DECAISSEMENT  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : 1 ligne par credit MIS EN PLACE (flux de production).
     Perimetre : decaissements du 1er janvier au 30 septembre de 2022, 2023, 2024
                 (fenetres comparables entre exercices). ND exclu (jamais decaisse).
     Sortie : NUM_DOSSIER, ARRETE_ID, DATE_EFFET_ID, COD_AGENCE, COD_GEST,
              COD_PRDT_CRD, COD_ADH, MONTANT_DECAISSE, ETAT_FINAL, EST_PERTE
     -> Lookups SSIS : COD_GEST -> GEST_ID ; COD_ADH -> CLIENT_ID

     POURQUOI cette table plutot que FACT_PRET : FACT_PRET est un SNAPSHOT, il ne
     contient que les prets encore vivants a l'arrete. Un credit decaisse en
     fevrier et solde en juin en est absent. Mesurer la production depuis le
     snapshot sous-estimerait donc fortement les exercices anciens (dont les
     credits courts sont deja soldes) et donnerait une fausse impression de
     croissance. Un flux de decaissement est indispensable.
-------------------------------------------------------------------------------*/
WITH exercices AS (
    SELECT 20220930 AS ARRETE_ID, CAST('2022-01-01' AS date) AS d1, CAST('2022-09-30' AS date) AS d2
    UNION ALL SELECT 20230930, CAST('2023-01-01' AS date), CAST('2023-09-30' AS date)
    UNION ALL SELECT 20240930, CAST('2024-01-01' AS date), CAST('2024-09-30' AS date)
),
ddem AS (
    SELECT REF_DEMANDE, COD_GEST, COD_PRDT_CRD, COD_ADH,
           ROW_NUMBER() OVER (PARTITION BY REF_DEMANDE ORDER BY DATE_VALIDATION DESC) AS rn
    FROM dbo.DEMPRET
)
SELECT
    p.NUM_DOSSIER,
    e.ARRETE_ID,
    CONVERT(int, CONVERT(char(8), p.DATE_EFFET, 112)) AS DATE_EFFET_ID,
    LEFT(p.NUM_DOSSIER, 3) AS COD_AGENCE,
    d.COD_GEST,
    d.COD_PRDT_CRD,
    d.COD_ADH,
    p.MONTANT_PRET AS MONTANT_DECAISSE,
    p.ETAT_PRET    AS ETAT_FINAL,
    CASE WHEN p.ETAT_PRET = 'PE' THEN 1 ELSE 0 END AS EST_PERTE
FROM dbo.PRETS p
JOIN exercices e ON p.DATE_EFFET >= e.d1 AND p.DATE_EFFET <= e.d2
LEFT JOIN ddem d ON d.REF_DEMANDE = p.REF_DEMANDE AND d.rn = 1
WHERE p.ETAT_PRET IN ('DC', 'SD', 'PE');
