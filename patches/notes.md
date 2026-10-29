MT Pack Organizer 0.9.31

- Janela de atualização substituída pelo diálogo escuro oficial, com versão, confirmação e botões roxos.
- Desfoque isolado apenas no conteúdo do aplicativo: o carregamento e seu painel permanecem nítidos depois de nomear o projeto.
- Gizmo revisado: removidos anéis e setas centrais; cantos fazem rotação horária/anti-horária, laterais giram um eixo e barras superior/inferior inclinam o outro. Realce âmbar discreto apenas no hover; Ctrl + rolagem altera a escala.
- Tela inicial compacta o resumo em uma faixa única e destaca os cartões de projetos com nomes, estatísticas, caminho e progresso mais legíveis.
- Testes adicionais de interface incluem diálogo de atualização e verificação de remoção do desfoque.

MT Pack Organizer 0.9.30

- Carregamento de projeto não herda o desfoque do diálogo de nomeação; o fundo volta ao foco antes da mensagem de indexação.
- Cabeçalho da página inicial não mostra mais o texto redundante "Meus projetos"; o nome e caminho do pack aparecem somente dentro do projeto.
- Teste de interface verifica a ausência do desfoque durante o carregamento e o cabeçalho limpo na página inicial.

MT Pack Organizer 0.9.25

- Correção crítica do progresso: migração do estado antigo da stream para a pasta do aplicativo, recuperação com cópia de segurança e bloqueio contra sobrescrever dados ilegíveis.
- Testes de reabertura confirmam que as marcações MANTER/EXCLUIR e o índice são restaurados.
- Nova página inicial em formato de painel, com cartões, progresso e ações CONTINUAR, RENOMEAR e REMOVER.
- Projetos recebem nomes próprios; ao criar, é possível informar o nome. O padrão é o nome do pack, não 'stream'.
- Botão de casinha no cabeçalho para voltar aos projetos.
- EXCLUIR PROJETO remove o cartão do painel e arquiva seu estado recuperável sem apagar arquivos de roupas.
- Iluminação redesenhada com botões e melhoria de contraste para roupas pretas.
- Caixa de transformação com moldura discreta, marcadores claros, setas coloridas e anéis de rotação inspirados no Photoshop.
- Apenas uma instância do aplicativo por vez.
- Preserva as correções de texturas embutidas, tratamento de RSC7 e geração FiveM.
# MT Pack Organizer 0.9.26

- A iluminação agora aumenta a visibilidade de detalhes nas texturas escuras por correção de gama, mantendo o fundo 3D escuro e fixo.
- Janela de nome de projeto corrigida: botão SALVAR e tecla Enter confirmam o nome; título simplificado e ícone oficial.
- Caixa de transformação revista com puxadores quadrados, eixos e centro projetado estável ao girar a peça.
- Janela do Windows informa seu aplicativo de relançamento e ícone para reduzir a associação com o PowerShell na barra de tarefas.

# MT Pack Organizer 0.9.27

- Três janelas de projeto redesenhadas com tema escuro, botões roxos, tipografia e espaçamento consistentes.
- Excluir projeto: confirmação visual com nome, caminho e indicação de que arquivos de roupa serão preservados.
- Abrir pack: navegador de pastas integrado ao aplicativo, com pastas e unidades, botão voltar e opção de colar caminho.
- Renomear projeto: janela sem barra branca do Windows, campo destacado e botão SALVAR NOME.
- Testes automáticos de abrir pasta, confirmar nome e cancelar exclusão.

# MT Pack Organizer 0.9.28

- Fundo do app desfocado automaticamente durante os menus Abrir projeto, Renomear e Excluir, restaurado ao fechar.
- Botões dos menus usam hover roxo, vinho ou cinza escuro, sem o azul do Windows; rolagem assume o estilo do aplicativo.
- Cabeçalho simplificado: removido ABRIR PACK redundante; novos projetos continuam pelo botão + NOVO PROJETO.
- Aviso de atualização transformado em botão ATUALIZAR com contraste e alinhamento próprios.
- Testes de interface verificam o desfoque durante a abertura das janelas.

# MT Pack Organizer 0.9.29

- Ferramenta de transformação 3D reestruturada: eixo azul de profundidade Y funcional, além do X vermelho e Z verde.
- Anéis de rotação independentes, com realce ativo e outros eixos atenuados; plano translúcido quando interage com a seleção.
- Escala pelos quatro cantos passa a usar a distância ao centro da seleção, sem inverter a direção em alguns cantos.
- Rotação no plano da tela usa movimento angular real ao redor do centro; os outros dois eixos usam sensibilidade proporcional à caixa.
- A moldura mantém largura/altura ao girar e altera a projeção quando a escala, o zoom ou a profundidade muda.
- Posição em profundidade agora é salva e restaurada junto com as demais configurações de visualização.
- Autoteste WPF de geometria verifica dimensões estáveis, movimento em profundidade e realce de controles.

