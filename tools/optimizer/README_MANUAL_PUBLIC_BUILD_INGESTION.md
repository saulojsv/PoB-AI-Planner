# Busca manual e ingestão de builds de PoE 1

## Fluxo vigente

A busca é feita manualmente nesta conversa, consultando as 40 fontes em `build-source-seeds-international.json`. Os IDs são comparados com `BuildIngestion\source-index.jsonl` e `source-validation-index.jsonl` antes de formar um lote. Skill, variante normal/transfigurada e patch anunciados pela página são pistas; a classificação final vem do PoB nativo.

O crawler e seus launchers foram removidos. Não há tarefa agendada nem processo de descoberta em segundo plano; a busca não continua depois que a conversa termina. `Invoke-PublicBuildIngestion.ps1` é apenas o importador: recebe um share já identificado, verifica `robots.txt`, evita hashes repetidos e valida o XML pelo PoB nativo. `PublicBuildImportSupport.psm1` contém somente as funções de leitura e transporte necessárias a essa importação.

## Ingestão local

O importador grava no formato usado pelo AI Planner: XML de origem, objeto PoB canônico, linhagem, proveniência, validação nativa e índices de cobertura. O destino é `%USERPROFILE%\Documents\Path of Building\OptimizerStudies\Builds`.

1. Crie um manifesto JSON seguindo os arquivos em `BuildIngestion\Manifests`.
2. Use um ID de share ainda ausente dos dois índices locais. Os provedores de share suportados incluem PoBBin, PoB Codes e PoEDB; registre em `discoveryPageUrl` a página onde o share foi encontrado e em `sourceUrl` a origem do share. O importador confere o hash do export e, depois da leitura nativa, pula uma linhagem que já esteja no arquivo.
3. Execute:

```powershell
pwsh -NoProfile -File ".\tools\optimizer\Invoke-PublicBuildIngestion.ps1" `
  -ManifestPath "%USERPROFILE%\Documents\Path of Building\OptimizerStudies\BuildIngestion\Manifests\<manifesto>.json" `
  -UserDirectedLocalStudy
```

O importador consulta um share de cada vez, respeita `robots.txt`, aguarda no mínimo cinco segundos entre requisições e interrompe o lote em respostas 403 ou 429. A validação identifica skill principal, variante, classe, patch e integridade do perfil pelo PoB instalado.

## Classificação nativa

Uma página encontrada não basta para contar a build. Confirme que o XML foi carregado e reserializado pelo PoB; depois conte apenas a linhagem nativa distinta cuja Main Skill, variante e patch correspondam à linha de cobertura. O intake manual não cria uma segunda observação canônica quando a mesma linhagem já está arquivada; esse resultado fica registrado no índice de validação. Builds completas com ascendência secundária ou nó de evento ficam arquivadas com a razão de escopo registrada, mas não aumentam a cobertura estrita do Planner. Não altere os rótulos nativos para tornar esses casos elegíveis.

## Cobertura e duplicação

O alvo é 10 linhagens distintas por identidade de skill e patch. Use o índice nativo por linhagem e a CSV gerada por `Read-BuildCoverageSummary.ps1`; não infira cobertura pelo número de URLs, códigos, variantes de orçamento ou XMLs.

- `BuildIngestion\source-index.jsonl` — shares e proveniência.
- `BuildIngestion\source-validation-index.jsonl` — resultado da leitura nativa do PoB.
- `BuildIngestion\ManualCoverage-current-*.csv` — cobertura por patch, skill e variante.
- `BuildIngestion\Batches\batch-*.json` — resultado detalhado de cada importação.

Não consulte endpoints de perfil do PoE Ninja antes de completar uma passada pelos outros 39 seeds em todo o catálogo de skills da patch. Depois disso, mantenha pelo menos 300 segundos entre requisições ao PoE Ninja. Fontes sem share PoB identificável ficam como pistas de pesquisa, não como builds contadas. O importador não inicia pesquisas nem percorre o catálogo por conta própria.

## Rotina de pesquisa por rodada

1. Abra o snapshot e a fila `ManualCoverageQueue-*.csv`; priorize as identidades com maior déficit e mantenha separadas as variantes normal, transfigurada e vaal que existam no catálogo.
2. Consulte os seeds internacionais em grupos de idioma e use buscas pela skill/variante, patch e termos de PoB. Registre no review quais páginas/sites foram realmente consultados; uma busca web parcial não significa que todos os 40 domínios foram varridos.
3. Extraia os links de share e compare as IDs em `source-index.jsonl` e `source-validation-index.jsonl` antes de importar. Se uma página publicar várias etapas do mesmo personagem, escolha uma versão representativa final/endgame; não conte cada etapa de progressão como personagem/build independente.
4. Monte lotes de até três shares. Isso mantém o tempo de validação nativa controlado. O PoB decide Main Skill, variante, árvore, perfil completo e escopo; não substitua uma classificação nativa por título, DPS anunciado ou pressuposto de que todo perfil é apto.
5. Após o lote, atualize o snapshot amplo e documente separadamente novos shares, novas linhagens, resultados `in_scope` e bloqueios de cálculo. Só conte linhagens distintas confirmadas pelo arquivo nativo.
6. Comece a consultar perfis do PoE Ninja somente depois de concluir os outros 39 seeds em todo o catálogo da patch; então respeite a pausa mínima de 300 segundos entre requisições.
## Rodadas rápidas sem crawler

1. Consulte a fila de cobertura e selecione até três identidades em falta, mantendo normal, transfigurada e Vaal separadas.
2. Faça quatro consultas web agrupadas por idioma/domínio para incluir os 40 seeds; use patch, nome exato da variante e termos PoB/share. Registre quais domínios foram incluídos na consulta e quais páginas foram abertas. Uma consulta agrupada não vale como leitura direta de todos os 40 sites nem como passagem completa por todas as skills.
3. Para cada share, confira os dois índices antes de formar o lote. Um código com resultado terminal já validado é duplicata. Uma observação apenas pendente deve ser resolvida pela validação nativa, sem contar como build até o PoB concluir.
4. Importe no máximo três shares por lote. Guarde um perfil final por personagem/linhagem; não transforme loadouts, níveis ou etapas de progressão em builds diferentes.
5. Recalcule a cobertura após cada lote com a mesma evidência de revalidação histórica usada pelo snapshot anterior. Conte a linhagem apenas na identidade exata de skill e variante confirmada pelo PoB. Relate separadamente cobertura ampla e escopo estrito do Planner.
6. Registre no review da rodada os sites consultados, páginas abertas, IDs duplicados, shares indisponíveis, linhagens novas, skills/variantes e arquivos de saída. Só declare uma varredura integral depois de visitar cada domínio e cada identidade da patch; resultados de busca por palavra-chave não provam cobertura completa.
