#!/bin/bash

# TRUEBACKUP .

readonly NOME_PROGRAMA="TRUEBACKUP"
readonly VERSAO_PROGRAMA="1.0"

# Códigos de retorno da versão simplificada.
readonly RETORNO_SUCESSO=0
readonly RETORNO_ERRO=1
readonly RETORNO_USO=2

# Localização da configuração persistente.
DIRETORIO_BASE_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}"
DIRETORIO_CONFIG="${DIRETORIO_BASE_CONFIG}/truebackup"
ARQUIVO_CONFIG="${DIRETORIO_CONFIG}/config"

# Valores carregados da configuração.
DIRETORIO_ORIGEM=""
DIRETORIO_BACKUP=""
MAX_SNAPSHOTS=""

# IDs dos snapshots finais em ordem cronológica.
SNAPSHOTS=()

# Mostra a ajuda e as opções disponíveis.
EXIBIR_AJUDA() {
    printf '%s\n' \
        "${NOME_PROGRAMA} ${VERSAO_PROGRAMA}" \
        "" \
        "O TRUEBACKUP é um programa de backup versionado." \
        "Ele cria cópias de uma pasta escolhida pelo usuário e mantém" \
        "diferentes versões através de snapshots." \
        "" \
        "No primeiro backup todos os arquivos são copiados." \
        "Nos backups seguintes, arquivos que não foram alterados podem" \
        "ser reutilizados através de hard links, economizando espaço." \
        "Arquivos novos ou modificados são copiados normalmente." \
        "" \
        "O programa também permite listar os backups criados," \
        "restaurar uma versão anterior e limitar a quantidade de snapshots." \
        "" \
        "Uso:" \
        "  ./truebackup.sh" \
        "  ./truebackup.sh h" \
        "  ./truebackup.sh help" \
        "" \
        "Menu:" \
        "  1. Criar backup" \
        "  2. Listar backups" \
        "  3. Restaurar backup" \
        "  4. Configurar" \
        "  5. Sair"
}

# Salva uma mensagem no arquivo de log.
REGISTRAR_LOG() {
    local MENSAGEM_LOG="$1" DATA_LOG=""
    local ARQUIVO_LOG="${DIRETORIO_BACKUP}/truebackup.log"

    # Só grava quando o destino já estiver preparado.
    if [[ -z "$DIRETORIO_BACKUP" || ! -d "$DIRETORIO_BACKUP" ]]; then
        return "$RETORNO_ERRO"
    fi
    # Obtém a data usada no registro.
    if ! DATA_LOG="$(date '+%Y-%m-%d %H:%M:%S')"; then
        return "$RETORNO_ERRO"
    fi
    # Usa >> para adicionar a mensagem sem apagar o log anterior.
    if ! printf '%s | %s\n' "$DATA_LOG" "$MENSAGEM_LOG" >> "$ARQUIVO_LOG"; then
        return "$RETORNO_ERRO"
    fi
    return "$RETORNO_SUCESSO"
}

# Lê as três linhas CHAVE=VALOR sem executar o arquivo.
CARREGAR_CONFIGURACAO() {
    local CHAVE_CONFIG="" VALOR_CONFIG=""
    DIRETORIO_ORIGEM=""
    DIRETORIO_BACKUP=""
    MAX_SNAPSHOTS=""

    # Verifica se o arquivo de configuração existe.
    if [[ ! -f "$ARQUIVO_CONFIG" ]]; then
        printf 'Configuração não encontrada. Use a opção 4 do menu.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Lê cada linha e preserva espaços no valor.
    while IFS='=' read -r CHAVE_CONFIG VALOR_CONFIG || [[ -n "$CHAVE_CONFIG" ]]; do
        # Separa os três valores usados pelo programa.
        case "$CHAVE_CONFIG" in
            DIRETORIO_ORIGEM) DIRETORIO_ORIGEM="$VALOR_CONFIG" ;;
            DIRETORIO_BACKUP) DIRETORIO_BACKUP="$VALOR_CONFIG" ;;
            MAX_SNAPSHOTS) MAX_SNAPSHOTS="$VALOR_CONFIG" ;;
            *)
                printf 'Linha de configuração inválida: %s\n' "$CHAVE_CONFIG" >&2
                return "$RETORNO_ERRO"
                ;;
        esac
    done < "$ARQUIVO_CONFIG"
    return "$RETORNO_SUCESSO"
}

# Verifica somente os valores essenciais da configuração.
VALIDAR_CONFIGURACAO() {
    # Primeiro verifica se nenhum valor ficou vazio.
    if [[ -z "$DIRETORIO_ORIGEM" || -z "$DIRETORIO_BACKUP" || -z "$MAX_SNAPSHOTS" ]]; then
        printf 'Informe origem, destino e limite de snapshots.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Remove barras finais desnecessárias, preservando a raiz.
    while [[ "$DIRETORIO_ORIGEM" != "/" && "$DIRETORIO_ORIGEM" == */ ]]; do
        DIRETORIO_ORIGEM="${DIRETORIO_ORIGEM%/}"
    done
    # Normaliza também o destino antes de comparar os caminhos.
    while [[ "$DIRETORIO_BACKUP" != "/" && "$DIRETORIO_BACKUP" == */ ]]; do
        DIRETORIO_BACKUP="${DIRETORIO_BACKUP%/}"
    done
    # Os caminhos precisam ser absolutos para o backup funcionar corretamente.
    if [[ "$DIRETORIO_ORIGEM" != /* || "$DIRETORIO_BACKUP" != /* ]]; then
        printf 'Origem e destino devem usar caminhos absolutos.\n' >&2
    # Confirma que a origem realmente existe.
    elif [[ ! -d "$DIRETORIO_ORIGEM" ]]; then
        printf 'O diretório de origem não existe: %s\n' "$DIRETORIO_ORIGEM" >&2
    # Impede que o destino seja a própria origem.
    elif [[ "$DIRETORIO_ORIGEM" == "$DIRETORIO_BACKUP" ]]; then
        printf 'Origem e destino devem ser diferentes.\n' >&2
    # Evita copiar os snapshots para dentro deles mesmos.
    elif [[ "$DIRETORIO_ORIGEM" == "/" || "$DIRETORIO_BACKUP" == "$DIRETORIO_ORIGEM/"* ]]; then
        printf 'O destino não pode ficar dentro da origem.\n' >&2
    # Evita criar a estrutura diretamente na raiz ou no HOME.
    elif [[ "$DIRETORIO_BACKUP" == "/" || "$DIRETORIO_BACKUP" == "$HOME" ]]; then
        printf 'O destino não pode ser / nem o diretório HOME.\n' >&2
    # Exige um limite inteiro e maior que zero.
    elif [[ ! "$MAX_SNAPSHOTS" =~ ^[1-9][0-9]*$ ]]; then
        printf 'O limite deve ser um número inteiro positivo.\n' >&2
    # Se nenhuma validação falhou, a configuração está correta.
    else
        return "$RETORNO_SUCESSO"
    fi
    return "$RETORNO_ERRO"
}

# Cria o destino e o diretório que guarda os snapshots.
PREPARAR_DESTINO() {
    # Interrompe quando a estrutura não pode ser criada.
    if ! mkdir -p -- "${DIRETORIO_BACKUP}/snapshots"; then
        printf 'Não foi possível preparar o destino: %s\n' "$DIRETORIO_BACKUP" >&2
        return "$RETORNO_ERRO"
    fi
    # Confirma que o destino aceita escrita.
    if [[ ! -w "$DIRETORIO_BACKUP" ]]; then
        printf 'O destino não permite escrita: %s\n' "$DIRETORIO_BACKUP" >&2
        return "$RETORNO_ERRO"
    fi
    return "$RETORNO_SUCESSO"
}

# Solicita e salva a configuração do usuário.
CONFIGURAR() {
    printf 'Diretório de origem: '
    IFS= read -r DIRETORIO_ORIGEM
    printf 'Diretório de destino dos backups: '
    IFS= read -r DIRETORIO_BACKUP
    printf 'Quantidade máxima de snapshots: '
    IFS= read -r MAX_SNAPSHOTS

    # Não salva a configuração se os valores forem inválidos.
    if ! VALIDAR_CONFIGURACAO; then
        return "$RETORNO_ERRO"
    fi
    # Cria o diretório da configuração.
    if ! mkdir -p -- "$DIRETORIO_CONFIG"; then
        printf 'Não foi possível criar: %s\n' "$DIRETORIO_CONFIG" >&2
        return "$RETORNO_ERRO"
    fi
    # Prepara o repositório escolhido pelo usuário.
    if ! PREPARAR_DESTINO; then
        return "$RETORNO_ERRO"
    fi
    # Grava exatamente três linhas no formato CHAVE=VALOR.
    if ! printf 'DIRETORIO_ORIGEM=%s\nDIRETORIO_BACKUP=%s\nMAX_SNAPSHOTS=%s\n' \
        "$DIRETORIO_ORIGEM" "$DIRETORIO_BACKUP" "$MAX_SNAPSHOTS" > "$ARQUIVO_CONFIG"; then
        printf 'Não foi possível salvar a configuração.\n' >&2
        return "$RETORNO_ERRO"
    fi
    REGISTRAR_LOG "configuração alterada"
    printf 'Configuração salva em: %s\n' "$ARQUIVO_CONFIG"
    return "$RETORNO_SUCESSO"
}

# Verifica o rsync e oferece sua instalação quando necessário.
VERIFICAR_DEPENDENCIAS() {
    local RESPOSTA_INSTALACAO=""
    local -a COMANDO_INSTALACAO=()

    # Se o rsync já estiver instalado, não precisa fazer mais nada.
    if command -v rsync > /dev/null 2>&1; then
        return "$RETORNO_SUCESSO"
    fi
    printf 'A dependência rsync não está instalada.\n'
    # Verifica se o sistema possui apt-get para instalar o rsync.
    if ! command -v apt-get > /dev/null 2>&1; then
        printf 'apt-get não foi encontrado. Instale o pacote rsync manualmente.\n' >&2
        return "$RETORNO_ERRO"
    fi
    printf 'Deseja instalar o rsync agora? [s/N]: '
    IFS= read -r RESPOSTA_INSTALACAO
    # Só continua a instalação se o usuário responder s ou S.
    case "$RESPOSTA_INSTALACAO" in
        s|S) ;;
        *)
            printf 'Instalação cancelada.\n'
            return "$RETORNO_ERRO"
            ;;
    esac

    # Executa apt-get diretamente quando o usuário já é root.
    if [[ "$EUID" -eq 0 ]]; then
        COMANDO_INSTALACAO=("apt-get")
    # Usa sudo para um usuário comum quando ele estiver disponível.
    elif command -v sudo > /dev/null 2>&1; then
        COMANDO_INSTALACAO=("sudo" "apt-get")
    # Sem root ou sudo, o script não consegue instalar automaticamente.
    else
        printf 'Execute como root ou instale sudo para instalar o rsync.\n' >&2
        return "$RETORNO_ERRO"
    fi

    # Atualiza a lista de pacotes antes da instalação confirmada.
    if ! "${COMANDO_INSTALACAO[@]}" update; then
        printf 'Não foi possível atualizar a lista de pacotes.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Instala somente o pacote necessário ao projeto.
    if ! "${COMANDO_INSTALACAO[@]}" install -y rsync; then
        printf 'Não foi possível instalar o rsync.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Confirma que o comando passou a estar disponível.
    if ! command -v rsync > /dev/null 2>&1; then
        printf 'O rsync ainda não está disponível.\n' >&2
        return "$RETORNO_ERRO"
    fi
    printf 'rsync instalado com sucesso.\n'
    return "$RETORNO_SUCESSO"
}

# Busca os snapshots existentes e guarda seus IDs no array.
OBTER_SNAPSHOTS() {
    local CAMINHO_SNAPSHOT="" ID_SNAPSHOT="" SNAPSHOTS_ORDENADOS=""
    SNAPSHOTS=()

    # Percorre os diretórios sem interpretar a saída de ls.
    for CAMINHO_SNAPSHOT in "${DIRETORIO_BACKUP}/snapshots"/*; do
        ID_SNAPSHOT="${CAMINHO_SNAPSHOT##*/}"
        # Aceita somente diretórios com o formato de ID esperado.
        if [[ -d "$CAMINHO_SNAPSHOT" \
            && "$ID_SNAPSHOT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(_[0-9]{2})?$ ]]; then
            SNAPSHOTS+=("$ID_SNAPSHOT")
        fi
    done

    # Ordena o array quando existe mais de um snapshot.
    if [[ "${#SNAPSHOTS[@]}" -gt 1 ]]; then
        SNAPSHOTS_ORDENADOS="$(printf '%s\n' "${SNAPSHOTS[@]}" | sort)"
        SNAPSHOTS=()
        # Coloca os IDs ordenados de volta no array.
        while IFS= read -r ID_SNAPSHOT; do
            SNAPSHOTS+=("$ID_SNAPSHOT")
        done <<< "$SNAPSHOTS_ORDENADOS"
    fi
    return "$RETORNO_SUCESSO"
}

# Remove os snapshots mais antigos acima do limite configurado.
APLICAR_RETENCAO() {
    local ID_MAIS_ANTIGO="" CAMINHO_MAIS_ANTIGO=""
    OBTER_SNAPSHOTS

    # Enquanto houver backups demais, remove o mais antigo.
    while [[ "${#SNAPSHOTS[@]}" -gt "$MAX_SNAPSHOTS" ]]; do
        ID_MAIS_ANTIGO="${SNAPSHOTS[0]}"
        CAMINHO_MAIS_ANTIGO="${DIRETORIO_BACKUP}/snapshots/${ID_MAIS_ANTIGO}"
        # Confere o caminho antes de usar rm -rf.
        if [[ ! "$ID_MAIS_ANTIGO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(_[0-9]{2})?$ \
            || "$CAMINHO_MAIS_ANTIGO" != "${DIRETORIO_BACKUP}/snapshots/${ID_MAIS_ANTIGO}" \
            || ! -d "$CAMINHO_MAIS_ANTIGO" ]]; then
            printf 'A retenção recusou um caminho inesperado.\n' >&2
            return "$RETORNO_ERRO"
        fi
        # Interrompe se o snapshot antigo não puder ser removido.
        if ! rm -rf -- "$CAMINHO_MAIS_ANTIGO"; then
            printf 'Não foi possível remover o snapshot: %s\n' "$ID_MAIS_ANTIGO" >&2
            return "$RETORNO_ERRO"
        fi
        REGISTRAR_LOG "snapshot removido pela retenção: ${ID_MAIS_ANTIGO}"
        SNAPSHOTS=("${SNAPSHOTS[@]:1}")
    done
    return "$RETORNO_SUCESSO"
}

# Cria um snapshot completo ou incremental.
CRIAR_BACKUP() {
    local ID_BASE_SNAPSHOT="" ID_SNAPSHOT="" ID_ANTERIOR=""
    local DIRETORIO_ANTERIOR="" DIRETORIO_TEMPORARIO="" DIRETORIO_FINAL=""
    local TENTATIVA=0

    # Carrega os dados necessários para iniciar o backup.
    if ! CARREGAR_CONFIGURACAO || ! VALIDAR_CONFIGURACAO \
        || ! VERIFICAR_DEPENDENCIAS || ! PREPARAR_DESTINO; then
        return "$RETORNO_ERRO"
    fi
    OBTER_SNAPSHOTS
    # Pega o último backup para servir de referência ao incremental.
    if [[ "${#SNAPSHOTS[@]}" -gt 0 ]]; then
        ID_ANTERIOR="${SNAPSHOTS[${#SNAPSHOTS[@]} - 1]}"
        DIRETORIO_ANTERIOR="${DIRETORIO_BACKUP}/snapshots/${ID_ANTERIOR}"
    fi
    # Usa a data e a hora como ID do novo snapshot.
    if ! ID_BASE_SNAPSHOT="$(date '+%Y-%m-%d_%H%M%S')"; then
        printf 'Não foi possível gerar o ID do snapshot.\n' >&2
        return "$RETORNO_ERRO"
    fi
    ID_SNAPSHOT="$ID_BASE_SNAPSHOT"
    DIRETORIO_TEMPORARIO="${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}.tmp"
    DIRETORIO_FINAL="${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}"
    # Se o nome já existir, tenta _01, _02 e assim por diante.
    until [[ ! -e "$DIRETORIO_FINAL" && ! -e "$DIRETORIO_TEMPORARIO" ]]; do
        TENTATIVA=$((TENTATIVA + 1))
        # Limita as colisões a sufixos de _01 até _99.
        if [[ "$TENTATIVA" -gt 99 ]]; then
            printf 'Não foi possível gerar um ID livre.\n' >&2
            return "$RETORNO_ERRO"
        fi
        printf -v ID_SNAPSHOT '%s_%02d' "$ID_BASE_SNAPSHOT" "$TENTATIVA"
        DIRETORIO_TEMPORARIO="${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}.tmp"
        DIRETORIO_FINAL="${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}"
    done

    # Cria o diretório temporário que receberá o rsync.
    if ! mkdir -- "$DIRETORIO_TEMPORARIO"; then
        printf 'Não foi possível criar o snapshot temporário.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Usa link-dest quando existe um snapshot anterior.
    if [[ -n "$ID_ANTERIOR" ]]; then
        if ! rsync -a "--link-dest=$DIRETORIO_ANTERIOR" -- "$DIRETORIO_ORIGEM/" "$DIRETORIO_TEMPORARIO/"; then
            printf 'Falha durante o backup incremental.\n' >&2
            REGISTRAR_LOG "erro de backup incremental"
            # Remove somente o temporário conhecido desta execução.
            if [[ -d "$DIRETORIO_TEMPORARIO" \
                && "$DIRETORIO_TEMPORARIO" == "${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}.tmp" ]]; then
                rm -rf -- "$DIRETORIO_TEMPORARIO"
            fi
            return "$RETORNO_ERRO"
        fi
    # No primeiro backup ainda não há referência, então copia tudo.
    else
        if ! rsync -a -- "$DIRETORIO_ORIGEM/" "$DIRETORIO_TEMPORARIO/"; then
            printf 'Falha durante o backup completo.\n' >&2
            REGISTRAR_LOG "erro de backup completo"
            # Remove somente o temporário conhecido desta execução.
            if [[ -d "$DIRETORIO_TEMPORARIO" \
                && "$DIRETORIO_TEMPORARIO" == "${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}.tmp" ]]; then
                rm -rf -- "$DIRETORIO_TEMPORARIO"
            fi
            return "$RETORNO_ERRO"
        fi
    fi

    # Depois que o rsync termina, troca o .tmp pelo nome definitivo.
    if ! mv -- "$DIRETORIO_TEMPORARIO" "$DIRETORIO_FINAL"; then
        printf 'Não foi possível publicar o snapshot.\n' >&2
        REGISTRAR_LOG "erro ao publicar snapshot: ${ID_SNAPSHOT}"
        # Remove somente o temporário que ainda estiver no caminho esperado.
        if [[ -d "$DIRETORIO_TEMPORARIO" \
            && "$DIRETORIO_TEMPORARIO" == "${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}.tmp" ]]; then
            rm -rf -- "$DIRETORIO_TEMPORARIO"
        fi
        return "$RETORNO_ERRO"
    fi
    REGISTRAR_LOG "backup concluído: ${ID_SNAPSHOT}"
    # Depois do backup, remove versões antigas se passar do limite.
    if ! APLICAR_RETENCAO; then
        printf 'O backup foi criado, mas a retenção falhou.\n' >&2
        return "$RETORNO_ERRO"
    fi
    printf 'Backup criado com sucesso: %s\n' "$ID_SNAPSHOT"
    return "$RETORNO_SUCESSO"
}

# Lista os snapshots e sua quantidade de arquivos.
LISTAR_SNAPSHOTS() {
    local ID_SNAPSHOT="" CAMINHO_SNAPSHOT="" QUANTIDADE_ARQUIVOS=""

    # Carrega a configuração antes de listar os backups.
    if ! CARREGAR_CONFIGURACAO || ! VALIDAR_CONFIGURACAO || ! PREPARAR_DESTINO; then
        return "$RETORNO_ERRO"
    fi
    OBTER_SNAPSHOTS
    # Informa quando ainda não existem backups finais.
    if [[ "${#SNAPSHOTS[@]}" -eq 0 ]]; then
        printf 'Nenhum backup disponível.\n'
        return "$RETORNO_SUCESSO"
    fi
    printf '%-24s | %8s\n' "ID" "ARQUIVOS"
    # Mostra uma linha para cada snapshot do array.
    for ID_SNAPSHOT in "${SNAPSHOTS[@]}"; do
        CAMINHO_SNAPSHOT="${DIRETORIO_BACKUP}/snapshots/${ID_SNAPSHOT}"
        QUANTIDADE_ARQUIVOS="$(find "$CAMINHO_SNAPSHOT" -type f | wc -l)"
        printf '%-24s | %8s\n' "$ID_SNAPSHOT" "$QUANTIDADE_ARQUIVOS"
    done
    return "$RETORNO_SUCESSO"
}

# Restaura todo o conteúdo de um snapshot.
RESTAURAR_SNAPSHOT() {
    local ID_RESTAURACAO="$1" DESTINO_RESTAURACAO="$2"
    local ID_SNAPSHOT="" DIRETORIO_SNAPSHOT="" CONTEUDO_DESTINO=""
    local RESPOSTA_CONFIRMACAO="" SNAPSHOT_ENCONTRADO=0

    # Carrega os dados e confirma a disponibilidade do rsync.
    if ! CARREGAR_CONFIGURACAO || ! VALIDAR_CONFIGURACAO \
        || ! VERIFICAR_DEPENDENCIAS || ! PREPARAR_DESTINO; then
        return "$RETORNO_ERRO"
    fi
    OBTER_SNAPSHOTS
    # Procura o ID informado entre os snapshots finais.
    for ID_SNAPSHOT in "${SNAPSHOTS[@]}"; do
        # Quando encontra o ID escolhido, para a busca.
        if [[ "$ID_SNAPSHOT" == "$ID_RESTAURACAO" ]]; then
            SNAPSHOT_ENCONTRADO=1
            break
        fi
    done
    # Recusa um ID ausente ou um destino vazio.
    if [[ "$SNAPSHOT_ENCONTRADO" -eq 0 || -z "$DESTINO_RESTAURACAO" ]]; then
        printf 'Snapshot ou destino inválido.\n' >&2
        return "$RETORNO_ERRO"
    fi
    DIRETORIO_SNAPSHOT="${DIRETORIO_BACKUP}/snapshots/${ID_RESTAURACAO}"
    # O destino do restore precisa ser uma pasta.
    if [[ -e "$DESTINO_RESTAURACAO" && ! -d "$DESTINO_RESTAURACAO" ]]; then
        printf 'O destino da restauração não é um diretório.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Verifica se um diretório existente já contém dados.
    if [[ -d "$DESTINO_RESTAURACAO" ]]; then
        CONTEUDO_DESTINO="$(find "$DESTINO_RESTAURACAO" -mindepth 1 -print -quit)"
    fi
    # Se já houver arquivos no destino, pergunta antes de sobrescrever.
    if [[ -n "$CONTEUDO_DESTINO" ]]; then
        printf 'O destino contém dados. Continuar? [s/N]: '
        IFS= read -r RESPOSTA_CONFIRMACAO
        # Somente s ou S autoriza a restauração.
        case "$RESPOSTA_CONFIRMACAO" in
            s|S) ;;
            *)
                printf 'Restauração cancelada.\n'
                return "$RETORNO_SUCESSO"
                ;;
        esac
    fi
    # Cria o destino quando ele ainda não existe.
    if ! mkdir -p -- "$DESTINO_RESTAURACAO"; then
        printf 'Não foi possível criar o destino da restauração.\n' >&2
        return "$RETORNO_ERRO"
    fi
    # Copia o snapshot completo para o destino escolhido.
    if ! rsync -a -- "$DIRETORIO_SNAPSHOT/" "$DESTINO_RESTAURACAO/"; then
        printf 'Falha durante a restauração.\n' >&2
        return "$RETORNO_ERRO"
    fi
    REGISTRAR_LOG "restore concluído: ${ID_RESTAURACAO}"
    printf 'Restauração concluída com sucesso.\n'
    return "$RETORNO_SUCESSO"
}

# Mantém as cinco opções da interface acadêmica.
MENU_PRINCIPAL() {
    local OPCAO_MENU="" ID_SNAPSHOT_MENU="" DESTINO_MENU=""

    # Repete o menu até o usuário escolher sair.
    while true; do
        clear
        printf '%s\n' "" "=== ${NOME_PROGRAMA} ===" \
            "1. Criar backup" \
            "2. Listar backups" \
            "3. Restaurar backup" \
            "4. Configurar" \
            "5. Sair"
        printf 'Escolha uma opção: '
        # Encerra normalmente quando a entrada padrão termina.
        if ! IFS= read -r OPCAO_MENU; then
            printf '\n'
            return "$RETORNO_SUCESSO"
        fi
        # Executa a função escolhida no menu.
        case "$OPCAO_MENU" in
            1) CRIAR_BACKUP ;;
            2) LISTAR_SNAPSHOTS ;;
            3)
                printf 'ID do snapshot: '
                IFS= read -r ID_SNAPSHOT_MENU
                printf 'Diretório de destino: '
                IFS= read -r DESTINO_MENU
                RESTAURAR_SNAPSHOT "$ID_SNAPSHOT_MENU" "$DESTINO_MENU"
                ;;
            4) CONFIGURAR ;;
            5)
                printf 'Encerrando o %s.\n' "$NOME_PROGRAMA"
                return "$RETORNO_SUCESSO"
                ;;
            *) printf 'Opção inválida. Escolha um número entre 1 e 5.\n' >&2 ;;
        esac
        printf '\nPressione Enter para voltar ao menu...'
        IFS= read -r
    done
}

# Aceita somente menu, h ou help.
PRINCIPAL() {
    local ARGUMENTO_PRINCIPAL=""

    # Abre o menu quando não existem argumentos.
    if [[ "$#" -eq 0 ]]; then
        MENU_PRINCIPAL
        return "$?"
    fi
    # Rejeita mais de um parâmetro.
    if [[ "$#" -ne 1 ]]; then
        printf 'Parâmetro inválido. Use: ./truebackup.sh help\n' >&2
        return "$RETORNO_USO"
    fi
    ARGUMENTO_PRINCIPAL="$1"
    # Aceita h ou help como parâmetro de ajuda.
    case "$ARGUMENTO_PRINCIPAL" in
        h|help)
            EXIBIR_AJUDA
            return "$RETORNO_SUCESSO"
            ;;
        *)
            printf 'Parâmetro inválido: %s\n' "$ARGUMENTO_PRINCIPAL" >&2
            printf 'Use: ./truebackup.sh help\n' >&2
            return "$RETORNO_USO"
            ;;
    esac
}

PRINCIPAL "$@"
