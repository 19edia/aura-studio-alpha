# AURA Wallpaper Studio

O **AURA Wallpaper Studio** é uma ferramenta portátil e open source para Windows que permite trocar o papel de parede de forma simples, inclusive quando as opções de personalização estão limitadas em uma instalação do Windows não ativada.

> O AURA **não ativa o Windows**, não altera chaves de licença e não tenta contornar o sistema de ativação.
>
> Ele apenas utiliza recursos já existentes no próprio Windows para definir o wallpaper do usuário atual.

## Por que este projeto existe?

Em algumas instalações do Windows não ativadas, o menu:

**Configurações > Personalização > Plano de Fundo**

pode ficar limitado.

Ainda assim, o próprio Windows possui APIs capazes de alterar o wallpaper.

O AURA cria uma interface simples para isso:

1. Abra o programa.
2. Escolha uma imagem.
3. Escolha a resolução.
4. Clique em **Aplicar wallpaper**.

Pronto.

Sem precisar editar o Registro manualmente, executar vários comandos ou instalar programas adicionais.

## 🔒 Isso é vírus?

O código-fonte completo está dentro do próprio arquivo `Wallpaper_Aura.bat` e pode ser aberto com qualquer editor de texto.

O programa:

- NÃO baixa arquivos da internet.
- NÃO envia informações para servidores.
- NÃO possui sistema de telemetria.
- NÃO coleta senhas ou informações pessoais.
- NÃO modifica a ativação do Windows.
- NÃO altera chaves de licença.
- NÃO desativa Windows Defender ou antivírus.
- NÃO cria tarefas agendadas.
- NÃO adiciona o programa à inicialização do Windows.
- NÃO instala serviços.
- NÃO modifica `HKLM`.
- NÃO solicita privilégios de administrador.

As alterações relacionadas ao wallpaper são feitas somente para o **usuário atual**.

O projeto utiliza componentes nativos do Windows, incluindo:

`Windows PowerShell`
`WPF`
`System.Drawing`
`user32.dll`

Você pode verificar todo o funcionamento diretamente no código antes de executar.

## ⚠️ Por que meu antivírus pode desconfiar do arquivo?

O AURA é um arquivo BAT que contém um programa PowerShell embutido.

Alguns antivírus e o Microsoft SmartScreen utilizam sistemas de detecção por comportamento e reputação. Scripts `.bat` que iniciam PowerShell podem receber avisos mesmo quando não possuem código malicioso.

Por isso, recomenda-se sempre baixar o programa diretamente deste repositório.

O projeto é open source justamente para que qualquer pessoa possa verificar exatamente o que será executado.

Um alerta do SmartScreen ou de um antivírus não significa automaticamente que um arquivo seja malicioso, mas você nunca deve ignorar alertas cegamente. Analise o código e faça suas próprias verificações.

## 🧠 Como o AURA funciona?

O arquivo possui duas partes.

A primeira parte é um pequeno inicializador BAT.

Ela localiza o Windows PowerShell e lê o próprio arquivo até encontrar:

`#==AURA_POWERSHELL==`

Todo o código abaixo desse marcador é carregado como PowerShell.

Isso permite que toda a aplicação continue sendo distribuída como **um único arquivo**.

A interface gráfica é construída utilizando **WPF**, tecnologia nativa do Windows.

Quando uma imagem é selecionada, o programa utiliza `System.Drawing` para carregá-la e prepará-la.

Os formatos atualmente aceitos são:

`JPG`
`JPEG`
`PNG`
`BMP`

O AURA também corrige automaticamente a orientação EXIF de fotos feitas por celulares e câmeras.

## 🖼️ Resoluções

O usuário pode manter a resolução original ou converter a imagem para:

**Full HD**
1920 × 1080

**4K**
3840 × 2160

**8K**
7680 × 4320

Quando uma resolução específica é escolhida, o AURA preserva a proporção da imagem e utiliza um recorte central para preencher completamente a tela.

O redimensionamento utiliza interpolação bicúbica de alta qualidade.

## 💾 Onde o wallpaper é armazenado?

Depois do processamento, o AURA cria uma versão BMP da imagem em:

`%LocalAppData%\AuraWallpaper`

Os arquivos possuem nomes aleatórios semelhantes a:

`aura-6f040a2cf60d4876acb147fb176cca93.bmp`

O programa não modifica nem apaga a imagem original escolhida pelo usuário.

Quando um novo wallpaper criado pelo próprio AURA é aplicado, o programa pode excluir somente o wallpaper anterior criado pelo AURA dentro dessa mesma pasta.

Ele verifica o nome e o diretório antes da exclusão para evitar remover arquivos externos.

## 🪟 Como o wallpaper é aplicado?

O AURA modifica somente estas configurações do usuário atual:

`HKEY_CURRENT_USER\Control Panel\Desktop`

As propriedades utilizadas são:

`WallpaperStyle`

e

`TileWallpaper`

Depois disso, ele utiliza a função oficial do Windows:

`SystemParametersInfoW`

presente em:

`user32.dll`

com a operação:

`SPI_SETDESKWALLPAPER`

Essa API informa ao Windows que um novo wallpaper deve ser utilizado.

Não é necessário reiniciar o computador.

## 🛡️ Proteção contra erros

Antes de alterar as configurações de enquadramento do wallpaper, o AURA guarda os valores anteriores.

Se o Windows rejeitar a troca do wallpaper, o programa tenta restaurar essas configurações.

A imagem processada também é inicialmente criada como um arquivo temporário `.part`.

Somente depois que a gravação é concluída com sucesso ela se torna o arquivo BMP definitivo.

Isso reduz o risco de deixar arquivos incompletos no cache.

## 📦 Precisa instalar alguma coisa?

Não.

O projeto foi desenvolvido para funcionar como um único arquivo:

`Wallpaper_Aura.bat`

Não existe uma pasta obrigatória junto do programa.

Não existem DLLs próprias.

Não existe instalador.

Não existe servidor externo.

O programa depende apenas de componentes presentes no próprio Windows.

## 🔑 Precisa ativar o Windows?

Não.

E o programa também **não ativa o Windows**.

O AURA simplesmente utiliza a API de wallpaper que já existe no sistema operacional.

Ele não interfere no sistema de licenciamento da Microsoft.

## 👑 Precisa executar como administrador?

Não.

O AURA trabalha nas configurações do usuário atual e foi projetado para funcionar sem privilégios administrativos.

## 🔍 Quer verificar por conta própria?

Isso é incentivado.

Clique com o botão direito em:

`Wallpaper_Aura.bat`

e abra o arquivo utilizando:

**Bloco de Notas**
**Notepad++**
**Visual Studio Code**

Todo o programa pode ser lido.

Procure por funções como:

`Invoke-AuraWallpaper`

`SystemParametersInfoW`

`SetWallpaper`

e pelo marcador:

`#==AURA_POWERSHELL==`

Não existe código escondido em um executável separado.

## ⚠️ Aviso

Este projeto não é afiliado, patrocinado ou aprovado pela Microsoft.

Windows é uma marca registrada da Microsoft Corporation.

O AURA Wallpaper Studio é apenas uma ferramenta independente para gerenciamento de wallpapers.
