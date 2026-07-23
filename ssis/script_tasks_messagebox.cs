/*===============================================================================
  Projet : Portfolio Power BI - Qualite du portefeuille de credit (EMF)
  Fichier: script_tasks_messagebox.cs  (extraits a coller dans des Taches de script SSIS)
  Objet  : Afficher une boite de dialogue au DEBUT et a la FIN de chaque package.
  Langage: Script Task -> ScriptLanguage = "Microsoft Visual C# 2019"
  Variable: ajouter System::PackageName dans ReadOnlyVariables de chaque tache.
  NB     : MessageBox bloque l'execution jusqu'au clic et exige une session
           interactive. Parfait pour une demo dans Visual Studio, a NE PAS
           utiliser pour une execution planifiee/sans surveillance (SQL Agent),
           ou cela resterait bloque indefiniment.
===============================================================================*/


/*-------------------------------------------------------------------------------
  TACHE DE SCRIPT  "SCR_DEBUT"  (a placer tout en haut du Control Flow)
-------------------------------------------------------------------------------*/
public void Main()
{
    string nomPipeline = Dts.Variables["System::PackageName"].Value.ToString();

    System.Windows.Forms.MessageBox.Show(
        "Demarrage du pipeline : " + nomPipeline + "\n"
        + "Heure : " + System.DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss"),
        "SSIS - Debut d'execution",
        System.Windows.Forms.MessageBoxButtons.OK,
        System.Windows.Forms.MessageBoxIcon.Information);

    Dts.TaskResult = (int)ScriptResults.Success;
}


/*-------------------------------------------------------------------------------
  TACHE DE SCRIPT  "SCR_FIN"  (a placer tout en bas du Control Flow)
-------------------------------------------------------------------------------*/
public void Main()
{
    string nomPipeline = Dts.Variables["System::PackageName"].Value.ToString();

    System.Windows.Forms.MessageBox.Show(
        "Fin d'execution du pipeline : " + nomPipeline + "\n"
        + "Heure : " + System.DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss"),
        "SSIS - Execution terminee",
        System.Windows.Forms.MessageBoxButtons.OK,
        System.Windows.Forms.MessageBoxIcon.Information);

    Dts.TaskResult = (int)ScriptResults.Success;
}
