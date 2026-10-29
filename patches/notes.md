MT Pack Organizer 0.9.38

- Substituído o ícone de voltar por uma casa sólida roxo-clara com telhado, paredes e porta central.
- Removidos totalmente os botões extras de giro/inclinação; a caixa delimitadora permanece como único controle de transformação 3D.
- Vista inicial de p_head, p_eyes e p_ears recebe orientação frontal/vertical automaticamente; orientações manuais antigas dos botões não são mais reaplicadas.
- Teste de interface verifica a nova casa sólida e a ausência de botões extras de orientação.

MT Pack Organizer 0.9.37

- AJUDA sem interrogação e com conteúdo exclusivamente sobre uso e atualizações; botão SUPORTE separado no rodapé do modal, vinculado ao convite oficial do Discord MT STUDIO.
- Ícone de casa redesenhado com telhado, paredes e porta reconhecíveis.
- TODAS AS CATEGORIAS retorna à primeira peça, conforme fluxo de revisão solicitado.
- ÚLTIMA PENDENTE busca desde o início a primeira peça não marcada em toda a ordem do pack, sem depender do filtro anterior; seleciona TODAS AS CATEGORIAS quando necessário.
- Brincos p_ears recebem a orientação inicial de prévia que já existia para chapéus e óculos (inclinação 90° e orientação frontal), com botões manuais de ajuste.
- Testes de UI atualizados para o fluxo global de pendências e reinício da categoria.

MT Pack Organizer 0.9.36

- Botão PRÓXIMA PENDENTE: encontra a próxima peça sem decisão no filtro de categoria ativo, com retorno circular ao início, sem alterar as marcações existentes; informa quando a categoria está totalmente revisada.
- Alternar de uma categoria específica para TODAS AS CATEGORIAS não devolve mais a navegação à primeira peça: a seleção atual é preservada sempre que pertence ao filtro.
- Carregamento reformulado com painel de preparação mais legível, atividade real exibindo contagem de arquivos YDD/YTD encontrados e orientações úteis, sem falsa porcentagem.
- Indexação otimizada com listas dinâmicas em vez de concatenações crescentes de arrays para peças e variantes, reduzindo custo em packs grandes; atualizações visuais periódicas durante a busca.
- Botão AJUDA no cabeçalho abre um painel de instruções, atalhos, segurança dos arquivos, suporte MT STUDIO e localização das atualizações.
- Testes Windows incluem salto à próxima pendente, preservação da posição ao alternar filtros e estado de categoria totalmente revisada.

MT Pack Organizer 0.9.35

- Tela inicial reformulada como painel comercial compacto: hierarquia visual mais clara, botão de criação em destaque e totais de projetos, peças revisadas, mantidas e excluídas.
- Cartões dos projetos com status de andamento/conclusão, espaçamentos consistentes e ação de continuar destacada; nomes, decisões, caminhos e progresso permanecem disponíveis.
- Organizador com tipografia mais legível, painéis alinhados, melhor contraste dos textos secundários e cartões de decisão e geração de add-on refinados.
- Identidade roxa MT STUDIO uniformizada em controles, bordas, campos e rodapé; caixa delimitadora 3D e fluxos de projeto preservados.
- Cache de texturas decodificadas limitado por orçamento estimado de RAM (192 MiB) e quantidade, cache de malhas limitado e miniaturas agendadas com prioridade de segundo plano para reduzir pressão em PCs modestos.

MT Pack Organizer 0.9.34

- Removido inteiramente o retângulo roxo grande do interior da caixa delimitadora.
- A região vazia da seleção não ativa mais a movimentação no eixo Z; somente a seta verde do manipulador central faz esse movimento.
- Mantidos os três eixos centrais, a moldura cinza fina e as faixas/quadrados roxo-claros de rotação que aparecem no hover.
- Testes confirmam a ausência de destaque central e a separação entre a região vazia e a seta Z.

MT Pack Organizer 0.9.33

- Manipulador central 3D restaurado com setas nos eixos X (vermelho), Y (azul/profundidade) e Z (verde/altura), cada uma com hover e arraste específicos.
- Plano de destaque da região interna reduzido com margens de 34 px nas laterais e 29 px em cima/baixo, sem encostar na moldura da caixa.
- Todas as áreas de hover da caixa passaram de amarelo-alaranjado para roxo-claro, alinhado à identidade MT STUDIO.
- Mantém moldura fina e faixas/cantos condicionais da v0.9.32; testes verificam os três eixos centrais e o tamanho do plano.

MT Pack Organizer 0.9.32

- Caixa delimitadora reconstruída com base nas referências do Photoshop 3D: só a moldura cinza fina permanece visível depois de selecionar a peça; nenhum quadrado, barrinha ou anel aparece parado.
- Mouse sobre o canto: aparecem quatro planos quadrados âmbar, e arrastar gira no eixo Z (horário/anti-horário).
- Mouse sobre uma borda lateral: aparecem duas faixas verticais âmbar, e arrastar gira no eixo Y.
- Mouse sobre a borda superior/inferior: aparecem duas faixas horizontais âmbar, e arrastar gira no eixo X.
- Mouse na região interna: aparece somente o plano de movimento no eixo Z; Alt + arrastar move livremente. Ctrl + rolagem redimensiona sem alterar a rotação.
- Destaques se apagam ao sair da caixa ou desfazer a seleção. Os controles são selecionados por regiões geométricas do mouse, não por elementos pequenos permanentes.
- Testes verificam as quatro regiões do mouse, os destaques exclusivos por eixo e a estabilidade dimensional da caixa ao girar.

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

