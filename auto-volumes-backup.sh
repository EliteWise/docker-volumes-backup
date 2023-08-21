#!/usr/bin/env bash
(

dependencies=("tar" "scp" "ssh" "docker")
# Vérifie l'existence des dependencies
for cmd in "${dependencies[@]}"; do
  if ! command -v $cmd &> /dev/null; then
    echo "Erreur : $cmd n'est pas installé."
    exit 1
  fi
done

# Vérifier le premier argument
if [[ $1 == "config" ]]; then
    # Inclure le fichier config
    source config.sh
else
    # Vérifier que l'utilisateur a fourni les arguments nécessaires
    if [[ $# -lt 3 ]]; then
        echo "Usage: $0 [config] OR $0 [REMOTE_USER] [REMOTE_HOST] [REMOTE_PATH]"
        exit 1
    else
        # Configuration
        REMOTE_USER="$1"
        REMOTE_HOST="$2"
        REMOTE_PATH="$3"

        BACKUP_FOLDER="./backups"
        VOLUME_PATH="./volumes"
        BACKUP_FILE="backup_$(date +"%Y%m%d%H%M%S").tar.gz"
        BACKUP_PATH="$BACKUP_FOLDER/$BACKUP_FILE"

        SSH_KEY_PATH="/root/.ssh/backup-ssh"

        SETUP_CRON=false
        CRON_SCHEDULE="0 2 * * *"

        SAVE_BIND_MOUNTS=true
        SAVE_NAMED_VOLUMES=false

        DELETE_RECENT=false

        for arg in "$@"; do
          if [ "$arg" == '--named-volumes' ]; then
              SAVE_NAMED_VOLUMES=true
              break
          fi
        done
    fi
fi

# Vérifie si le dossier backups existe, sinon le crée
if [[ ! -d "./backups" ]]; then
    mkdir "./backups"
    if [[ $? -ne 0 ]]; then
        echo "Erreur lors de la création du dossier 'backups'."
        exit 1
    fi
fi

if [[ "$SAVE_NAMED_VOLUMES" = true ]]; then
  if docker volume ls -q | grep -q "^${VOLUME_NAME}$"; then
    # Crée une archive du volume
    sudo tar -czvf "${BACKUP_PATH}" -C "/var/lib/docker/volumes/${VOLUME_NAME}/_data" .
    if [[ $? -eq 0 ]]; then
      echo "Archive créée avec succès dans ${BACKUP_PATH}"
    else
      echo "Erreur lors de la création de l'archive."
    fi
  else
      echo "Le volume $VOLUME_NAME n'existe pas."
  fi
fi

# Crée une archive du dossier "volumes"
sudo tar czvf $BACKUP_PATH -C $VOLUME_PATH ./
if [[ $? -ne 0 ]]; then
    echo "Erreur lors de la création de l'archive."
    exit 1
fi

# Vérifie que la clé SSH a les bonnes permissions
chmod 600 "$SSH_KEY_PATH"

SCRIPT_PATH="$(dirname "$(readlink -f "$0")")"

if [[ "$SETUP_CRON" = true ]]; then
    if ! crontab -l | grep -q "path_to_your_script"; then
        (crontab -l ; echo "$CRON_SCHEDULE /bin/bash $SCRIPT_PATH/$(basename "$0")") | crontab -
        echo "Cron job configuré pour s'exécuter selon : $CRON_SCHEDULE"
    else
        echo "Cron job déjà configuré pour ce script."
    fi
fi

# Envoie la sauvegarde au premier poste distant
scp -i "$SSH_KEY_PATH" $BACKUP_PATH $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH
if [[ $? -ne 0 ]]; then
    echo "Erreur lors de l'envoi de la sauvegarde au serveur distant."
    exit 1
fi

if [[ "$DELETE_RECENT" = true ]]; then
  # Supprime les archives plus anciennes sur le serveur distant
  ssh -i "$SSH_KEY_PATH" $REMOTE_USER@$REMOTE_HOST <<
  EOF
    cd $REMOTE_PATH

    # Obtiens le timestamp du fichier le plus récemment modifié
    newest_timestamp=$(stat --format=%Y -- "$(ls -t | head -n 1)")

    # Parcourt chaque fichier/dossier pour vérifier son timestamp
    for file in *; do
      file_timestamp=$(stat --format=%Y -- "$file")

      # Si le fichier/dossier est plus ancien que le plus récent, le supprime
      if [[ $file_timestamp -lt $newest_timestamp ]]; then
        rm -r "$file"
      fi
    done
  EOF
fi

echo "Sauvegarde réussie et envoyée au serveur distant."

# Redirige la sortie standard et la sortie d'erreur vers le fichier "output.log"
) |& tee output.log
