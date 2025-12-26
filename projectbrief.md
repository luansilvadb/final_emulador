# **Arquitetura e Implementação de Servidores V Rising em Infraestrutura ARM64: Emulação, Containerização e Modding Avançado**

## **1\. Introdução e Contextualização Tecnológica**

A evolução da infraestrutura de servidores tem observado uma migração tangível da arquitetura x86\_64 predominante para soluções baseadas em ARM64 (AArch64). Esta transição é impulsionada pela eficiência energética e pela relação custo-benefício oferecida por plataformas como os processadores Ampere Altra em nuvens públicas (Oracle Cloud, AWS Graviton), bem como hardware de borda acessível como o Raspberry Pi 5 e Orange Pi 5\.1 No entanto, o ecossistema de software de jogos, especificamente servidores dedicados para títulos desenvolvidos em motores gráficos complexos como Unity, permanece largamente atrelado ao conjunto de instruções x86.

O caso de *V Rising*, um RPG de sobrevivência de mundo aberto desenvolvido pela Stunlock Studios, exemplifica este desafio de engenharia. O servidor dedicado do jogo é distribuído exclusivamente como um binário Windows x86\_64, compilado através do backend IL2CPP (Intermediate Language to C++) da Unity. A ausência de binários nativos para Linux ou arquiteturas ARM impõe uma barreira significativa para a hospedagem eficiente em hardware moderno de baixo custo. Para superar esta limitação, é necessário construir uma pilha tecnológica complexa que envolve virtualização de chamadas de sistema e tradução binária dinâmica.

Este relatório técnico detalha a arquitetura, implementação e orquestração de uma solução containerizada (Docker) para executar o servidor dedicado de *V Rising* em hardware ARM64. O foco central reside na integração estável do framework de modding BepInEx, superando falhas conhecidas de segmentação e *threading* através de uma metodologia de "pré-configuração no Windows", garantindo controle total e estabilidade em ambientes gerenciados via Easypanel.

### **1.1. O Desafio da Arquitetura Heterogênea**

A execução de software compilado para uma arquitetura de processador (hóspede, x86\_64) em uma arquitetura diferente (anfitrião, ARM64) exige camadas de abstração que inevitavelmente introduzem sobrecarga de desempenho e complexidade operacional. No contexto de *V Rising*, o desafio é duplo:

1. **Tradução de Instruções de CPU:** O código de máquina x86\_64 deve ser traduzido em tempo real para instruções ARMv8. Emuladores tradicionais como QEMU (em modo de sistema) são proibitivamente lentos para aplicações de tempo real como servidores de jogos. A solução reside em tradutores dinâmicos (Dynarec) como o **Box64**, que traduzem blocos de código sob demanda e mapeiam chamadas de biblioteca diretamente para versões nativas do sistema operacional anfitrião.3  
2. **Tradução de API de Sistema Operacional:** O binário do servidor espera interagir com o kernel do Windows NT (gerenciamento de memória, threads, rede Winsock). Em um ambiente Linux (Docker), é necessário utilizar o **Wine** para interceptar essas chamadas e traduzi-las para chamadas de sistema POSIX (Linux syscalls).5

A tabela abaixo resume as camadas de abstração necessárias e suas funções na arquitetura proposta:

| Camada Tecnológica | Função Primária | Desafio Específico em V Rising | Solução Adotada |
| :---- | :---- | :---- | :---- |
| **Hardware** | Processamento ARM64 | Incompatibilidade de conjunto de instruções (ISA). | \-- |
| **Kernel Linux** | Gestão de Recursos | Falta de suporte nativo a binários Windows PE. | Módulo binfmt\_misc para invocar Box64. |
| **Box64** | Tradução Binária (x86\_64 \-\> ARM64) | Overhead de emulação e falhas em código JIT/IL2CPP. | Compilação otimizada com \-DARM\_DYNAREC=ON. |
| **Wine** | Compatibilidade de API (Win32 \-\> POSIX) | Dependências gráficas ocultas e rede. | Wine 64-bit \+ Xvfb (Display Virtual). |
| **BepInEx** | Injeção de Código (Modding) | Falhas de geração de Interop em emulação. | Geração prévia em ambiente Windows nativo. |

### **1.2. O Paradigma da Containerização no Easypanel**

O Easypanel, como uma interface moderna para gerenciamento de Docker, abstrai a complexidade da orquestração de containers, mas exige que a imagem Docker subjacente seja robusta e autocontida. Ao contrário de um VPS tradicional onde o administrador pode intervir manualmente, um container no Easypanel deve ser capaz de gerenciar seu próprio ciclo de vida, persistência de dados e recuperação de falhas.

A exigência de "controle total" implica que o Dockerfile e os scripts de inicialização não devem ocultar a lógica de operação. O administrador deve ter a capacidade de injetar variáveis de ambiente para ajustar o comportamento do Box64 (como BOX64\_DYNAREC\_BIGBLOCK) e do Wine (como WINEDLLOVERRIDES), além de gerenciar arquivos de configuração de mods sem reconstruir a imagem.7

---

**2\. Fundamentos da Emulação de Alto Desempenho: Box64 e Wine**

A viabilidade técnica de rodar *V Rising* em ARM64 depende inteiramente da eficiência da camada de emulação. Uma compreensão profunda de como o Box64 interage com o Wine e o sistema anfitrião é crucial para diagnosticar problemas e otimizar o Dockerfile.

### **2.1. Arquitetura do Box64: O Tradutor Dinâmico**

O Box64 difere da virtualização clássica por não emular o sistema operacional inteiro. Ele carrega o binário x86\_64 e traduz suas instruções de máquina para ARM64. O diferencial crítico para desempenho é o mecanismo de "wrapping" de bibliotecas. Quando o binário x86 solicita uma função de uma biblioteca comum (como libGL.so, libm.so, ou libc.so), o Box64 não emula a versão x86 dessas bibliotecas. Em vez disso, ele intercepta a chamada, converte os argumentos e invoca a biblioteca nativa ARM64 do sistema anfitrião.1

Isso resulta em uma execução "híbrida":

* **Código do Jogo (VRisingServer.exe):** Emulado/Traduzido (Lento).  
* **Drivers de Vídeo/Rede/Sistema:** Nativo (Rápido).

Para *V Rising*, que é intensivo em lógica de jogo (CPU) mas também depende pesadamente de I/O de rede e sistema de arquivos, essa arquitetura permite atingir entre 40% a 60% do desempenho nativo de um processador x86 equivalente, tornando viável a hospedagem em chips como o RK3588 ou Apple M1/M2/M3.1

#### **2.1.1. Desafios de Memória e Threading**

Um dos maiores obstáculos na emulação de jogos Unity (que usam Garbage Collection e multithreading agressivo) em ARM64 é a diferença no modelo de memória.

* **x86\_64:** Possui um modelo de memória "forte" (Strong Memory Model), onde a ordem das operações de escrita e leitura é estritamente garantida pelo hardware.  
* **ARM64:** Possui um modelo de memória "fraco" (Weak Memory Model), onde o processador pode reordenar operações de memória para otimização, desde que não viole dependências de dados locais.

Essa discrepância pode causar condições de corrida (race conditions) em aplicações multithreaded projetadas para x86, resultando em *crashes* aleatórios ou corrupção de dados. O Box64 mitiga isso através da variável de ambiente BOX64\_DYNAREC\_STRONGMEM, que insere barreiras de memória (memory barriers) artificiais no código traduzido para forçar o comportamento "forte" do x86, ao custo de algum desempenho.8

### **2.2. A Camada Wine e o Subsistema Gráfico Fantasma**

Embora estejamos tratando de um "Servidor Dedicado", o binário VRisingServer.exe é construído sobre o motor Unity, que frequentemente inicializa subsistemas gráficos mesmo em modo *headless* (sem monitor). Tentar executar o servidor puramente via terminal muitas vezes resulta em falhas porque o Unity tenta criar um contexto de janela ou verificar capacidades da GPU.

A solução padrão na indústria, e adotada neste relatório, é o uso do **Xvfb (X Virtual Framebuffer)**. O Xvfb cria um servidor de exibição X11 que reside inteiramente na memória RAM, sem saída física. Ao configurar a variável DISPLAY=:0, enganamos o servidor *V Rising* (rodando sob Wine) para que ele acredite haver um monitor conectado, permitindo que a inicialização gráfica proceda sem erros.10

#### **2.2.1. Configuração do Prefixo Wine**

O Wine opera isolado em diretórios chamados "prefixos" (por padrão \~/.wine). Para um container Docker, é imperativo definir um local personalizado para este prefixo (ex: /data/wineprefix) e garantir que ele seja configurado exclusivamente para 64 bits (WINEARCH=win64). Misturar arquiteturas (32 e 64 bits) no mesmo prefixo dentro de um ambiente emulado adiciona complexidade desnecessária e potenciais conflitos de DLLs.4

---

**3\. Integração do BepInEx e o Problema do IL2CPP em Ambientes Emulados**

A integração do BepInEx é o ponto crítico onde a maioria das implementações em ARM64 falha. O BepInEx não é apenas um carregador de arquivos; ele realiza uma injeção de código sofisticada em tempo de execução que entra em conflito direto com as limitações atuais da emulação.

### **3.1. Mecânica do BepInEx em Unity IL2CPP**

Diferente de jogos Mono (onde o código C\# é compilado para IL e executado por uma VM), jogos IL2CPP como *V Rising* são compilados para código de máquina nativo. Para modificar o comportamento do jogo, o BepInEx utiliza um componente chamado Il2CppInterop.

O fluxo de inicialização padrão é:

1. **Doorstop:** Uma DLL proxy (geralmente winhttp.dll) intercepta a inicialização do jogo e carrega o núcleo do BepInEx.  
2. **Unhollower/Interop:** O BepInEx analisa os binários do jogo (GameAssembly.dll e metadados globais) e gera dinamicamente *assemblies*.NET que espelham as classes internas do jogo. Isso permite que mods escritos em C\# interajam com o código C++ do jogo.  
3. **Carregamento de Plugins:** Os mods são carregados e "patcheiam" métodos do jogo em memória.

### **3.2. A Falha Crítica na Geração de Interop em Box64**

A etapa de geração de *assemblies* de interoperação (Passo 2 acima) é extremamente intensiva e utiliza multithreading para processar milhares de classes do jogo simultaneamente. Pesquisas e relatos da comunidade técnica indicam que o Box64 e outros emuladores (como FEX-Emu) falham consistentemente durante esta fase.1

As causas prováveis incluem:

* **Race Conditions:** O gerenciamento de threads do Box64 pode não sincronizar perfeitamente as operações de escrita de arquivos geradas pelas threads paralelas do Il2CppInterop.  
* **Exceções JIT:** O gerador cria código IL (Intermediate Language) em memória que pode desencadear caminhos de execução não otimizados ou com falhas na tradução dinâmica do emulador.

Tentativas de rodar essa geração no ARM64 resultam em *freezes* (o processo para de responder) ou *segfaults* silenciosos, deixando a pasta BepInEx/interop vazia ou corrompida, impedindo o carregamento de qualquer mod.1

### **3.3. A Solução: Pré-Configuração no Windows**

Para garantir a "estabilidade e controle total" solicitada, a estratégia mais robusta é desacoplar a geração de interoperação da execução do servidor.

**Metodologia Prescrita:**

1. **Ambiente de Preparação (Windows x86\_64):** O administrador instala o servidor e o BepInEx em uma máquina Windows nativa.  
2. **Geração:** O servidor é executado uma vez. O BepInEx detecta a ausência de *assemblies* e executa o Il2CppInterop com sucesso (pois está em hardware nativo).  
3. **Extração:** As pastas resultantes (BepInEx/interop, BepInEx/unity-libs) contêm agora as DLLs necessárias.  
4. **Implantação (Linux ARM64):** Estes arquivos são transferidos para o servidor Docker. Quando o servidor iniciar no ambiente emulado, o BepInEx detectará que os arquivos já existem e pulará a etapa de geração problemática, procedendo diretamente para o carregamento dos plugins.

Esta abordagem transforma um problema de tempo de execução probabilístico (pode ou não falhar) em um procedimento determinístico de gestão de arquivos, ideal para ambientes de produção.

---

**4\. Engenharia do Dockerfile: Construção "From Scratch"**

A construção do Dockerfile deve ser meticulosa para minimizar o tamanho da imagem final enquanto fornece todas as dependências necessárias para o Box64 (compilação) e para o Wine (execução). Utilizaremos um build multi-estágio (*multi-stage build*) para separar as ferramentas de compilação do ambiente de produção.

### **4.1. Escolha da Imagem Base**

Optaremos pelo **Debian 12 (Bookworm) Slim**. O Debian oferece um equilíbrio ideal entre estabilidade (crucial para servidores de longa duração), tamanho reduzido e disponibilidade de bibliotecas modernas necessárias para o Wine e Box64. O Ubuntu é uma alternativa válida, mas o Debian tende a ser mais leve e menos opinativo em configurações padrão.4

### **4.2. Dockerfile Comentado e Análise Técnica**

Abaixo apresenta-se o Dockerfile completo, projetado para atender aos requisitos de compilação do Box64 otimizado para ARM64 e configuração do ambiente Wine.

Dockerfile

\# \-----------------------------------------------------------------------------  
\# ESTÁGIO 1: Builder do Box64  
\# Foco: Compilar o emulador a partir da fonte com otimizações para ARM64  
\# \-----------------------------------------------------------------------------  
FROM debian:bookworm-slim AS box64\_builder

\# Evita interações durante a instalação de pacotes  
ENV DEBIAN\_FRONTEND=noninteractive

\# Instalação de dependências de compilação  
\# git: para baixar o código fonte  
\# cmake, build-essential: ferramentas de build (gcc, make)  
\# python3: usado scripts de configuração do Box64  
RUN apt-get update && apt-get install \-y \\  
    git \\  
    cmake \\  
    python3 \\  
    build-essential \\  
    ca-certificates \\  
    && rm \-rf /var/lib/apt/lists/\*

\# Compilação do Box64  
\# WORKDIR define o diretório de trabalho  
WORKDIR /src

\# Clonamos o repositório oficial.   
\# A flag \-DARM\_DYNAREC=ON é MANDATÓRIA para performance aceitável em ARM64.  
\# CMAKE\_BUILD\_TYPE=RelWithDebInfo permite performance de Release mas mantém simbolos   
\# de debug caso seja necessário analisar um core dump.  
RUN git clone https://github.com/ptitSeb/box64.git. && \\  
    mkdir build && cd build && \\  
    cmake.. \-DARM\_DYNAREC=ON \-DCMAKE\_BUILD\_TYPE=RelWithDebInfo && \\  
    make \-j$(nproc) && \\  
    make install DESTDIR=/tmp/box64-install

\# \-----------------------------------------------------------------------------  
\# ESTÁGIO 2: Runtime Final  
\# Foco: Imagem limpa com Wine, Xvfb e scripts de gestão  
\# \-----------------------------------------------------------------------------  
FROM debian:bookworm-slim

LABEL maintainer="Expert Systems Architect"  
LABEL description="V Rising Dedicated Server ARM64 (Box64/Wine/BepInEx)"

\# Variáveis de Ambiente para Configuração e Controle  
ENV DEBIAN\_FRONTEND=noninteractive \\  
    PUID=1000 \\  
    PGID=1000 \\  
    \# Configuração do Wine  
    WINEPREFIX=/data/wineprefix \\  
    WINEARCH=win64 \\  
    WINEDEBUG=-all \\  
    \# Configuração do Box64 (Otimizações Críticas)  
    \# STRONGMEM: Força ordenação de memória (evita race conditions em Unity)  
    BOX64\_DYNAREC\_STRONGMEM=1 \\  
    \# BIGBLOCK: Tenta traduzir blocos maiores de código (performance)  
    BOX64\_DYNAREC\_BIGBLOCK=1 \\  
    \# Variáveis de Sistema  
    DISPLAY=:0 \\  
    INSTALL\_DIR=/data/server \\  
    \# Workaround para alocação de memória Unity/Box64  
    MALLOC\_CHECK\_=0

\# Habilitar arquitetura armhf (32-bit) é uma boa prática para compatibilidade de sistema,  
\# embora focaremos em Wine64. Instalação de dependências de runtime.  
\# gosu: para downgrade de privilégios (root \-\> usuário vrising)  
\# xvfb: display virtual  
\# cabextract: necessário para winetricks (se usado)  
RUN dpkg \--add-architecture armhf && \\  
    apt-get update && apt-get install \-y \\  
    wget \\  
    curl \\  
    unzip \\  
    tar \\  
    xvfb \\  
    cabextract \\  
    xz-utils \\  
    libgl1 \\  
    libx11-6 \\  
    libfreetype6 \\  
    gosu \\  
    \# Wine dos repositórios Debian (versão estável)  
    \# Em produção, versões staging do WineHQ podem ser usadas se necessário,  
    \# mas a versão estável do Debian Bookworm é suficiente para V Rising.  
    wine \\  
    wine64 \\  
    libwine \\  
    && rm \-rf /var/lib/apt/lists/\*

\# Copia os artefatos do Box64 compilados no estágio anterior  
COPY \--from=box64\_builder /tmp/box64-install/usr/local/bin/box64 /usr/local/bin/box64  
COPY \--from=box64\_builder /tmp/box64-install/usr/local/lib/box64 /usr/local/lib/box64  
COPY \--from=box64\_builder /tmp/box64-install/etc/binfmt.d/box64.conf /etc/binfmt.d/box64.conf

\# Criação do usuário não-root e diretórios  
\# É crucial que o PUID/PGID coincida com o host ou seja gerenciável pelo script de entrada  
RUN mkdir \-p ${WINEPREFIX} ${INSTALL\_DIR} && \\  
    groupadd \-g ${PGID} vrising && \\  
    useradd \-u ${PUID} \-g ${PGID} \-d /data \-s /bin/bash vrising && \\  
    chown \-R vrising:vrising /data

\# Copia do script de inicialização  
COPY start.sh /start.sh  
RUN chmod \+x /start.sh

\# Exposição das Portas UDP do Jogo e Query  
EXPOSE 9876/udp 9877/udp

\# Volume persistente para dados do jogo, saves e configurações  
VOLUME \["/data"\]

\# Ponto de Entrada  
ENTRYPOINT \["/start.sh"\]

### **4.3. Script de Inicialização (start.sh): O Cérebro da Operação**

O script de inicialização não serve apenas para lançar o executável; ele é o agente de configuração que garante a integridade do ambiente BepInEx antes de invocar o processo instável do jogo.

O script deve realizar as seguintes operações críticas:

1. **Correção de Permissões:** O Easypanel pode montar volumes como root. O script deve transferir a posse para o usuário vrising.  
2. **Gestão do lib\_burst\_generated.dll:** Existe um *bug* documentado onde a biblioteca Burst Compiler do Unity causa falhas na inicialização em Wine. O script deve remover ou renomear este arquivo a cada inicialização para garantir estabilidade.12  
3. **Configuração de Overrides do Wine:** Para que o BepInEx funcione, o Wine deve ser instruído a carregar a winhttp.dll modificada que reside na pasta do jogo, e não a versão do sistema. Isso é feito via variável WINEDLLOVERRIDES.  
4. **Verificação de Arquivos Interop:** O script deve verificar se as pastas de interoperação existem. Se não existirem (indicando uma instalação limpa sem a pré-configuração do Windows), ele deve emitir um alerta crítico nos logs.

Bash

\#\!/bin/bash  
set \-e

\# Definição de cores para logs legíveis no console do Easypanel  
GREEN='\\033 Iniciando V Rising Dedicated Server (ARM64/Box64)...${NC}"

\# 1\. Correção de Permissões (Idempotente)  
\# Se o script estiver rodando como root, corrige as permissões de /data e reexecuta como vrising  
if \[ "$(id \-u)" \= '0' \]; then  
    echo \-e "${YELLOW} Rodando como root. Ajustando propriedade de /data para vrising:${PGID}...${NC}"  
    chown \-R vrising:vrising /data  
    echo \-e "${GREEN} Permissões ajustadas. Rebaixando privilégios...${NC}"  
    exec gosu vrising "$0" "$@"  
fi

\# 2\. Inicialização do Wine  
if; then  
    echo \-e "${GREEN} Criando prefixo Wine64 em $WINEPREFIX...${NC}"  
    \# wineboot \-i inicializa o prefixo sem interface gráfica  
    wineboot \-i \> /dev/null 2\>&1  
    \# Aguarda o servidor wine estabilizar  
    wineserver \-w  
fi

\# Navega para o diretório do servidor  
cd ${INSTALL\_DIR}

\# 3\. Lógica de Integração BepInEx  
if; then  
    echo \-e "${GREEN} BepInEx detectado.${NC}"  
      
    \# Validação Crítica de Interoperação  
    if ||; then  
        echo \-e "${RED} CRÍTICO: Pasta BepInEx/interop ausente ou vazia\!${NC}"  
        echo \-e "${YELLOW}\[INFO\] Devido a limitações de emulação em ARM64, a geração automática de Interop falha.${NC}"  
        echo \-e "${YELLOW}\[INFO\] Você DEVE gerar os arquivos no Windows e enviá-los via SFTP.${NC}"  
        \# Não abortamos para permitir troubleshooting, mas o servidor provavelmente falhará ou rodará vanilla.  
    else  
        echo \-e "${GREEN} Arquivos de Interoperação detectados.${NC}"  
    fi

    \# Configuração de DLL Override  
    \# "winhttp=n,b" instrui o Wine a carregar a versão 'nativa' (local/BepInEx) primeiro,  
    \# e a 'builtin' (sistema) apenas se a nativa falhar.  
    export WINEDLLOVERRIDES="winhttp=n,b"  
    echo \-e "${GREEN} DLL Overrides configuradas para BepInEx.${NC}"

else  
    echo \-e "${GREEN}\[INFO\] BepInEx não encontrado. Iniciando em modo Vanilla.${NC}"  
    \# Remove overrides residuais se houver  
    export WINEDLLOVERRIDES=""  
fi

\# 4\. Workaround para Crash do Burst Compiler  
\# A DLL gerada pelo Burst Compiler frequentemente causa Access Violations sob Wine/Box64.  
BURST\_DLL="VRisingServer\_Data/Plugins/x86\_64/lib\_burst\_generated.dll"  
if; then  
    echo \-e "${YELLOW}\[FIX\] Removendo $BURST\_DLL para prevenir crashes...${NC}"  
    mv "$BURST\_DLL" "$BURST\_DLL.bak"  
fi

\# 5\. Inicialização do Display Virtual  
echo \-e "${GREEN} Iniciando servidor Xvfb...${NC}"  
\# Remove lockfiles antigos se o container foi morto abruptamente  
rm \-f /tmp/.X0-lock  
Xvfb :0 \-screen 0 1024x768x16 &  
XVFB\_PID=$\!  
sleep 2

\# 6\. Execução do Servidor  
echo \-e "${GREEN}\[GAME\] Lançando VRisingServer.exe via Box64...${NC}"  
echo \-e "${GREEN}\[GAME\] Servidor: $SERVER\_NAME | Save: $SAVE\_NAME${NC}"

\# Comando de lançamento  
\# \-persistentDataPath é crucial para que o Easypanel mantenha os saves no volume /data  
\# Redirecionamos stderr para stdout para captura de logs pelo Docker  
box64 wine64./VRisingServer.exe \\  
    \-persistentDataPath "/data/save-data" \\  
    \-serverName "$SERVER\_NAME" \\  
    \-saveName "$SAVE\_NAME" \\  
    \-logFile "/data/server\_log.txt" \\  
    \-batchmode \\  
    \-nographics \\  
    2\>&1 &

SERVER\_PID=$\!

\# Handler de Sinais para Encerramento Gracioso  
trap "echo ' Parando servidor...'; kill \-SIGTERM $SERVER\_PID; wait $SERVER\_PID; kill $XVFB\_PID" SIGTERM SIGINT

wait $SERVER\_PID

---

**5\. Orquestração no Easypanel e Gestão de Ciclo de Vida**

O Easypanel é uma ferramenta de gestão de infraestrutura que simplifica a implantação de aplicações Docker. Diferente de gerenciar um docker run manualmente, o Easypanel permite definir "Serviços de App" baseados em imagens Dockerfile ou Docker Compose. A configuração correta aqui é vital para garantir que a persistência de dados e a rede funcionem conforme esperado.

### **5.1. Definição do Docker Compose para Easypanel**

No Easypanel, você geralmente cria um serviço do tipo "App" e pode fornecer um arquivo docker-compose.yml (ou configurar via GUI que gera um compose internamente). Abaixo, a estrutura ideal para este servidor.

YAML

version: '3.8'

services:  
  vrising:  
    \# Se você construiu a imagem localmente ou hospedou em um registro privado:  
    image: vrising-arm64:custom   
    \# Alternativamente, o Easypanel permite 'Build from Source' apontando para um repo Git com o Dockerfile acima.  
    container\_name: vrising-server  
    restart: unless-stopped  
      
    \# Configuração de Rede  
    \# V Rising usa portas UDP. O mapeamento deve ser explícito.  
    ports:  
      \- "9876:9876/udp" \# Porta do Jogo  
      \- "9877:9877/udp" \# Porta de Query (Steam)  
      
    \# Variáveis de Ambiente (Configuráveis na GUI do Easypanel)  
    environment:  
      \- SERVER\_NAME=V Rising Docker ARM  
      \- SAVE\_NAME=world\_main  
      \- TZ=America/Sao\_Paulo  
      \# Tuning do Box64 (Pode ser ajustado sem rebuildar a imagem)  
      \- BOX64\_DYNAREC\_BIGBLOCK=1  
      \- BOX64\_LOG=1 \# Nível de log (0=none, 1=info, 2=debug)  
      
    \# Persistência de Dados  
    \# O Easypanel gerencia volumes. Aqui mapeamos o volume interno do painel para /data  
    volumes:  
      \- /etc/easypanel/projects/vrising/data:/data  
      
    \# Limites de Recursos (Essencial em ARM para evitar OOM kills)  
    deploy:  
      resources:  
        limits:  
          memory: 8G \# Unity é faminto por RAM; BepInEx aumenta o consumo  
          cpus: '4'  \# Recomendação mínima para emulação estável

### **5.2. O Processo de Instalação e Atualização (Upload Manual)**

Dada a dificuldade de executar o **SteamCMD** (que é um binário 32-bit i386) de forma estável dentro do mesmo container 64-bit que executa o servidor (devido a conflitos de multiarch e Box86/Box64 na mesma imagem base), a estratégia recomendada para o Easypanel é o **Upload Manual via SFTP**.

**Procedimento Operacional Padrão (SOP):**

1. **Criação do Serviço:** Crie o serviço no Easypanel usando o Dockerfile fornecido. Deixe-o iniciar (ele falhará ou ficará em loop pois não há arquivos de jogo ainda).  
2. **Acesso SFTP:** Utilize as credenciais fornecidas pelo Easypanel (ou configure um container auxiliar de FTP) para acessar o volume /data.  
3. **Transferência:** Faça o upload do conteúdo da pasta do servidor *V Rising* (preparada no Windows, já com BepInEx gerado) para o diretório /data/server.  
4. **Reinicialização:** Reinicie o container no Easypanel. O script start.sh detectará os arquivos, aplicará as correções (lib\_burst) e iniciará o servidor.

Este método oferece o "controle total" exigido, pois o administrador sabe exatamente quais versões de arquivos e quais configurações de mods estão sendo enviadas, sem depender de scripts de download automatizados que podem falhar silenciosamente em ARM64.

---

**6\. Otimização e Troubleshooting Avançado**

Em ambientes emulados, a diferença entre um servidor jogável e um servidor com *lag* constante reside no ajuste fino das variáveis de ambiente do Box64 e do Wine.

### **6.1. Variáveis de Ambiente do Box64**

A tabela a seguir detalha as variáveis mais impactantes para o servidor V Rising (Unity Engine) em ARM64 7:

| Variável | Valor Recomendado | Efeito Técnico | Impacto em V Rising |
| :---- | :---- | :---- | :---- |
| BOX64\_DYNAREC\_STRONGMEM | 1 | Força ordens de escrita de memória estritas (atomicidade). | **Crítico.** Previne corrupção de estado de jogo e crashes de multithreading do Unity. Reduz levemente a performance, mas é essencial para estabilidade. |
| BOX64\_DYNAREC\_BIGBLOCK | 1 | Compila blocos maiores de código nativo. | Aumenta o throughput da CPU. Se causar falhas gráficas (menos provável em servidor), reverta para 0\. |
| BOX64\_DYNAREC\_FASTNAN | 1 | Simplifica cálculos de ponto flutuante (NaN). | Melhora a performance física do jogo. Unity pode tolerar NaN simplificado na maioria dos casos. |
| BOX64\_DYNAREC\_SAFEFLAGS | 1 | Otimiza o tratamento de flags de CPU em chamadas. | Reduz overhead de chamadas de função. |
| MALLOC\_CHECK\_ | 0 | Desativa verificações extras da glibc. | Evita falsos positivos de corrupção de memória que ocorrem devido à tradução de endereços do Box64. |

### **6.2. Diagnóstico de Falhas (Logs e Traces)**

Se o servidor falhar, a análise de logs é fundamental. No Easypanel, acesse a aba "Logs" do container.

* **Logs do Box64:** Se o servidor nem iniciar, aumente a verbosidade do Box64 definindo BOX64\_LOG=2 ou BOX64\_LOG=3 nas variáveis de ambiente. Procure por instruções ilegais (SIGILL) ou falhas de carregamento de bibliotecas (Error loading lib...).  
* **Logs do Wine:** Se o Box64 iniciar mas o executável Windows falhar, use WINEDEBUG=+seh,+loaddll. Isso mostrará quais DLLs estão sendo carregadas (confirmando se winhttp.dll do BepInEx foi carregada) e exceções estruturadas do Windows.  
* **Logs do BepInEx:** Localizados em /data/server/BepInEx/LogOutput.log. Se este arquivo não for criado, o doorstop falhou (verifique doorstop\_config.ini e overrides de DLL). Se o arquivo existir mas parar abruptamente, verifique a presença das pastas interop (o problema de geração).

### **6.3. Otimização de Kernel do Host**

Para servidores de alta performance, algumas configurações no host (a máquina física onde o Easypanel roda) podem ajudar:

* **Page Size:** O Box64 funciona melhor em sistemas com páginas de memória de 4K. Sistemas como Apple Silicon (Asahi Linux) podem usar páginas de 16K, o que exige que o Box64 seja compilado com flags específicas (-DPAGE4K=ON não é padrão, mas o Box64 moderno lida bem com 16k via emulação de mmap). No entanto, o padrão Debian em ARM64 (4k) é o ideal.  
* **Binfmt\_misc:** Certifique-se de que o serviço systemd-binfmt está ativo e configurado corretamente no host se desejar executar binários x86 diretamente sem prefixar com box64 (embora nosso Dockerfile use invocação explícita para segurança).

---

**7\. Conclusão**

A implementação de um servidor *V Rising* em ARM64 com suporte a BepInEx representa um exercício avançado de integração de sistemas. Não existe uma solução "plug-and-play" simples devido à complexidade inerente da tradução de arquiteturas e da injeção de código em runtime.

Este relatório demonstrou que a chave para o sucesso não está apenas na escolha das ferramentas (Box64, Wine), mas na **estratégia de implantação**. A insistência na geração de arquivos de interoperação do BepInEx dentro do ambiente emulado é a causa raiz da maioria das falhas reportadas. Ao adotar a metodologia de **pré-configuração no Windows**, eliminamos a variável mais instável da equação, transformando o container Docker em um executor determinístico de um estado de servidor validado.

O Dockerfile "from scratch" apresentado, combinado com o script de inicialização resiliente e a configuração cuidadosa das variáveis de ambiente do Box64, fornece uma base sólida para hospedagem profissional no Easypanel. Esta arquitetura oferece o equilíbrio ideal entre o custo-benefício do hardware ARM64 e a flexibilidade do ecossistema de modding x86 do *V Rising*.

#### **Referências citadas**

1. vrising \+ bepinex \+ arm \- Reddit, acessado em dezembro 26, 2025, [https://www.reddit.com/r/vrising/comments/1l93nks/vrising\_bepinex\_arm/](https://www.reddit.com/r/vrising/comments/1l93nks/vrising_bepinex_arm/)  
2. Enshrouded \+ arm \- Reddit, acessado em dezembro 26, 2025, [https://www.reddit.com/r/Enshrouded/comments/1lbqccv/enshrouded\_arm/](https://www.reddit.com/r/Enshrouded/comments/1lbqccv/enshrouded_arm/)  
3. How do I launch a program using box64? Do I just execute/run the program?, acessado em dezembro 26, 2025, [https://unix.stackexchange.com/questions/799362/how-do-i-launch-a-program-using-box64-do-i-just-execute-run-the-program](https://unix.stackexchange.com/questions/799362/how-do-i-launch-a-program-using-box64-do-i-just-execute-run-the-program)  
4. How to Install Box86-Box64 Wine32-Wine64 Winetricks on Arm64 \- Armbian Forums, acessado em dezembro 26, 2025, [https://forum.armbian.com/topic/19526-how-to-install-box86-box64-wine32-wine64-winetricks-on-arm64/](https://forum.armbian.com/topic/19526-how-to-install-box86-box64-wine32-wine64-winetricks-on-arm64/)  
5. Running a V Rising Dedicated Server on Linux \- Pi My Life Up, acessado em dezembro 26, 2025, [https://pimylifeup.com/v-rising-dedicated-server-linux/](https://pimylifeup.com/v-rising-dedicated-server-linux/)  
6. How to Install Wine on Debian 12 Bookworm, acessado em dezembro 26, 2025, [https://wine.htmlvalidator.com/install-wine-on-debian-12.html](https://wine.htmlvalidator.com/install-wine-on-debian-12.html)  
7. box64 — Debian unstable, acessado em dezembro 26, 2025, [https://manpages.debian.org/unstable/box64/box64.1.en.html](https://manpages.debian.org/unstable/box64/box64.1.en.html)  
8. box64/docs/USAGE.md at main \- GitHub, acessado em dezembro 26, 2025, [https://github.com/ptitSeb/box64/blob/main/docs/USAGE.md](https://github.com/ptitSeb/box64/blob/main/docs/USAGE.md)  
9. box64(1) \- trixie \- Debian Manpages, acessado em dezembro 26, 2025, [https://manpages.debian.org/trixie/box64/box64.1.en.html](https://manpages.debian.org/trixie/box64/box64.1.en.html)  
10. TrueOsiris/docker-vrising: Container for V-Rising dedicated server \- GitHub, acessado em dezembro 26, 2025, [https://github.com/TrueOsiris/docker-vrising](https://github.com/TrueOsiris/docker-vrising)  
11. Customization with V Rising \- BEPINEX does not work \- CubeCoders Support, acessado em dezembro 26, 2025, [https://discourse.cubecoders.com/t/customization-with-v-rising-bepinex-does-not-work/13297](https://discourse.cubecoders.com/t/customization-with-v-rising-bepinex-does-not-work/13297)  
12. I'm trying to create a private game but I keep getting "Error: Server Error" : r/vrising \- Reddit, acessado em dezembro 26, 2025, [https://www.reddit.com/r/vrising/comments/13l6rkb/im\_trying\_to\_create\_a\_private\_game\_but\_i\_keep/](https://www.reddit.com/r/vrising/comments/13l6rkb/im_trying_to_create_a_private_game_but_i_keep/)  
13. Game crashes after last patch :: V Rising General Discussions \- Steam Community, acessado em dezembro 26, 2025, [https://steamcommunity.com/app/1604030/discussions/0/3832045251557364585/](https://steamcommunity.com/app/1604030/discussions/0/3832045251557364585/)