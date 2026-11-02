# Sites GitHub Pages en local

Version « poste de travail » des sites de `lslng` (`sites/` du dépôt) : mêmes confs
(`sites.d/*.json`), mais publiées dans un dossier local de ton choix, sans sudo ni systemd.

## Mise en route

```sh
cp github-pages.conf.example github-pages.conf   # puis adapte DEST
./publish.sh                                      # tous les sites de sites.d/
./publish.sh sites.d/mathpulse.json               # un seul site
./publish.sh -d ~/web                             # destination ponctuelle
./publish.sh -l                                   # liste ce qui est publié
```

Résultat : `<DEST>/<site>/index.html`. Pour les voir, n'importe quel serveur statique
convient, par exemple `python3 -m http.server -d "<DEST>" 8000`.

## Ce que fait le script

Pour chaque conf :
1. clone le dépôt (`--depth 1`, branche de la conf) dans un dossier temporaire ;
2. lance les commandes `build` dans le clone, dans l'ordre (`sh -ec`) ;
3. vérifie que `output/index.html` existe ;
4. remplace `<DEST>/<site>` par le nouveau contenu (dossier de staging, échange, puis suppression de l'ancien).

Un échec de build laisse la version précédente en place.

## Points d'attention

- **Le script exécute le contenu des dépôts sur ta machine** (`build`). Les dépôts sont ceux
  de `lstux` sur GitHub : lis les commandes dans `sites.d/*.json` avant de lancer.
- Dépendances : `git`, `jq`, et pour les builds `python3` ; Slovingo a besoin de Pillow et
  d'une police emoji (voir le README du dépôt Slovingo).
- Pas de rollback ici (contrairement au serveur) : pour revenir en arrière, relancer le
  publish d'une version précédente du dépôt.
- Un nouveau site = un nouveau fichier dans `sites.d/` (mêmes champs que sur lslng :
  `repo`, `branch`, `name`, `build`, `output`).
