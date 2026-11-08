# 🗂️ TRUEBACKUP — Automação de Backup Versionado em Bash

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![rsync](https://img.shields.io/badge/rsync-0A66C2?style=for-the-badge)

O **TRUEBACKUP** é um programa em **Shell Script (Bash)** que faz backups **versionados** de uma pasta escolhida pelo usuário. Cada execução gera um *snapshot* (uma "foto" da pasta naquele momento), e os arquivos que não mudaram entre um snapshot e outro **não são copiados de novo**: são reaproveitados com *hard links*, economizando espaço em disco.

Projeto desenvolvido em dupla na faculdade (Bacharelado em Sistemas de Informação, IFBA) e apresentado com conceitos de **Sistemas Operacionais**: hard links, processos, chamadas de sistema e atomicidade.

---

## ✨ Funcionalidades

- 📸 **Backup completo e incremental:** o primeiro backup copia tudo; os seguintes copiam só o que é novo ou foi modificado
- 🔗 **Economia de espaço** com `rsync --link-dest` (hard links para arquivos inalterados)
- 📋 **Listagem** dos snapshots com a quantidade de arquivos de cada um
- ♻️ **Restauração** de qualquer snapshot para uma pasta de destino, com confirmação antes de sobrescrever dados existentes
- 🧹 **Retenção automática:** mantém só os N snapshots mais recentes, removendo os mais antigos
- 📝 **Log** de operações (configuração, backups, remoções e restaurações)
- 🛡️ **Validações de segurança** na configuração (veja mais abaixo)
- 📦 **Verificação de dependência:** se o `rsync` não estiver instalado, oferece instalar via `apt-get`

---

## 🚀 Como usar

### Requisitos

- Linux com **Bash**
- **rsync** (o script oferece a instalação automática em sistemas com `apt-get`, como Ubuntu e Debian)
- Destino de backup em um sistema de arquivos que suporte **hard links** (ext4, por exemplo; FAT/exFAT não suportam)

### Executando

```bash
git clone https://github.com/CaioSimao01/automacao-backup-bash.git
cd automacao-backup-bash
chmod +x truebackup.sh
./truebackup.sh
```

Também é possível rodar sem dar permissão de execução: `bash truebackup.sh`.

### Menu

```
=== TRUEBACKUP ===
1. Criar backup
2. Listar backups
3. Restaurar backup
4. Configurar
5. Sair
```

1. Na primeira vez, use a opção **4. Configurar** e informe:
   - **Diretório de origem:** a pasta que será copiada (caminho absoluto)
   - **Diretório de destino:** onde os backups serão guardados (caminho absoluto)
   - **Quantidade máxima de snapshots:** quantas versões manter
2. Use **1. Criar backup** sempre que quiser gerar um novo snapshot.
3. Use **2. Listar backups** para ver os IDs disponíveis.
4. Use **3. Restaurar backup** informando o ID do snapshot e a pasta onde ele será restaurado.

### Ajuda pela linha de comando

```bash
./truebackup.sh help    # ou: ./truebackup.sh h
```

---

## ⚙️ Como funciona

### Estrutura criada no destino

```
destino/
├── truebackup.log
└── snapshots/
    ├── 2026-11-08_212522/      ← snapshot (ID = data_hora)
    ├── 2026-11-08_212523/
    └── 2026-11-08_212524/
```

A configuração fica salva em `~/.config/truebackup/config` (respeita `XDG_CONFIG_HOME`), em três linhas no formato `CHAVE=VALOR`. O script **lê** esse arquivo linha a linha em vez de executá-lo com `source`, para que ele nunca rode código arbitrário.

### Backup incremental com hard links

Quando já existe um snapshot anterior, o script chama:

```bash
rsync -a --link-dest=<snapshot_anterior> origem/ <novo_snapshot>.tmp/
```

Para cada arquivo, o `rsync` compara com o snapshot anterior:

- **Arquivo igual:** em vez de copiar, cria um *hard link* para o mesmo dado já gravado em disco
- **Arquivo novo ou modificado:** copia normalmente

Isso dá o efeito de ter "várias pastas completas", cada uma mostrando a pasta inteira como era naquele momento, mas ocupando só o espaço do que realmente mudou. Dá para confirmar olhando o número do *inode* (`ls -i`): o mesmo arquivo inalterado aparece com o **mesmo inode** em snapshots diferentes.

```text
$ ls -i snapshots/*/a.txt
679960 snapshots/2026-11-08_212522/a.txt
679960 snapshots/2026-11-08_212523/a.txt
```

Como cada snapshot tem seu próprio link para os dados, **apagar um snapshot antigo não quebra os mais novos**: o dado só é liberado do disco quando o último link para ele é removido. É isso que torna a retenção segura.

### Atomicidade: o snapshot só "existe" quando está completo

O backup é feito primeiro em uma pasta temporária com sufixo `.tmp`. Só depois que o `rsync` termina com sucesso é que ela é renomeada (`mv`) para o nome final. Como o `mv` dentro do mesmo sistema de arquivos é uma operação atômica, nunca aparece um snapshot pela metade na listagem. Se der erro no meio do caminho, o `.tmp` é removido e nenhum snapshot incompleto fica para trás.

### Validações da configuração

- origem e destino precisam ser **caminhos absolutos**
- a origem precisa **existir** e ser diferente do destino
- o destino **não pode ficar dentro da origem** (evita copiar os backups para dentro deles mesmos)
- o destino não pode ser `/` nem o diretório `HOME`
- o limite de snapshots precisa ser um **inteiro positivo**
- antes de usar `rm -rf` na retenção, o script confere se o ID tem o formato esperado e se o caminho é exatamente o previsto

### Códigos de retorno

| Código | Significado |
|--------|-------------|
| `0` | Sucesso |
| `1` | Erro de execução |
| `2` | Parâmetro de linha de comando inválido |

---

## 🧪 Exemplo de teste rápido

```bash
mkdir -p /tmp/origem/sub && echo a > /tmp/origem/a.txt && echo b > /tmp/origem/sub/b.txt
./truebackup.sh          # opção 4: origem=/tmp/origem, destino=/tmp/backups, máximo=2
                         # opção 1: criar o 1º backup (completo)
echo c >> /tmp/origem/a.txt
                         # opção 1: criar o 2º backup (incremental)
                         # opção 2: listar e ver os snapshots
                         # opção 3: restaurar um snapshot em /tmp/restaurado
```

---

## 📌 Limitações e ideias futuras

- A instalação automática do `rsync` funciona apenas com `apt-get` (Debian/Ubuntu e derivados)
- O destino precisa estar em um sistema de arquivos com suporte a hard links
- A restauração copia o snapshot inteiro (ainda não há restauração de um único arquivo)
- Ideias: agendamento com `cron`, opção de excluir arquivos/pastas e modo não interativo

---

## 👨‍💻 Autores

**Caio Simão** — estudante de Sistemas de Informação no IFBA

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/caio-simão-68400a3b1)
[![GitHub](https://img.shields.io/badge/GitHub-181717?style=flat&logo=github&logoColor=white)](https://github.com/CaioSimao01)

**Breno Souza Costa**
