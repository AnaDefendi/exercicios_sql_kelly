-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 🧱 Notebook 1 · Setup de Dados (Grupo Cóndor)
-- MAGIC
-- MAGIC Este notebook cria **todo o dataset de forma determinística** (mesmo
-- MAGIC resultado toda vez).
-- MAGIC
-- MAGIC > **Empresa fictícia — Grupo Cóndor:** conglomerado latino-americano com 3 unidades de
-- MAGIC > negócio: 🛒 **Cóndor Varejo** (lojas) · 💳 **Cóndor Pagos** (crédito ao consumo) ·
-- MAGIC > 🚚 **Cóndor Cargo** (logística). Dados 100% sintéticos.
-- MAGIC
-- MAGIC **O que este notebook cria em `workspace.grupo_condor`:**
-- MAGIC - Tabelas base: `dim_clientes`, `dim_lojas`, `fact_vendas`, `fact_creditos`, `fact_envios`
-- MAGIC - Camada **gold**: `gold_receita_diaria`, `gold_vendas_categoria`, `gold_carteira_creditos`, `gold_otif_envios`
-- MAGIC
-- MAGIC ⏱️ Tempo: ~2 minutos. Use um **SQL Warehouse Serverless** (na Free Edition já vem um).
-- MAGIC
-- MAGIC ### ⚙️ Antes de rodar — catálogo
-- MAGIC Na **Free Edition** o catálogo padrão é **`workspace`** (já usado abaixo). Se a sua conta
-- MAGIC usar outro catálogo (ex.: `main`), faça um **Find & Replace** (`Ctrl/Cmd + H`) trocando
-- MAGIC `workspace.grupo_condor` pelo `seu_catalogo.grupo_condor` neste notebook. É a única mudança.
-- MAGIC
-- MAGIC ▶️ Para rodar tudo: **Run all** (Executar tudo) no topo.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 1. Catálogo e schema

-- COMMAND ----------

USE CATALOG workspace;
CREATE SCHEMA IF NOT EXISTS workspace.grupo_condor;
USE SCHEMA grupo_condor;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2. Tabelas base (dados sintéticos determinísticos)
-- MAGIC Geração baseada em `hash()` do id → reprodutível, sem aleatoriedade instável.

-- COMMAND ----------

-- 2.1 · Clientes (2.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.dim_clientes AS
SELECT id+1 AS cliente_id,
  concat('Cliente ', lpad(cast(id+1 AS string),4,'0')) AS nome,
  element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pais'),7)+1) AS pais,
  concat('Cidade ', cast(pmod(hash(id,'cid'),40)+1 AS string)) AS cidade,
  CASE WHEN pmod(hash(id,'seg'),100) < 75 THEN 'B2C' ELSE 'B2B' END AS segmento,
  date_add(DATE'2023-01-01', pmod(hash(id,'alta'),1000)) AS data_cadastro
FROM range(2000);

-- COMMAND ----------

-- 2.2 · Lojas do Cóndor Varejo (120)
CREATE OR REPLACE TABLE workspace.grupo_condor.dim_lojas AS
SELECT id+1 AS loja_id,
  element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'p'),7)+1) AS pais,
  concat('Cidade ', cast(pmod(hash(id,'c'),40)+1 AS string)) AS cidade,
  element_at(array('SUPER','EXPRESS','ONLINE'), pmod(hash(id,'f'),3)+1) AS formato
FROM range(120);

-- COMMAND ----------

-- 2.3 · Vendas do Cóndor Varejo (50.000) — inclui a anomalia de ELETRO no Chile em Q1-2026
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_vendas AS
WITH b AS (
  SELECT id,
    id+1 AS venda_id,
    pmod(hash(id,'cli'),2000)+1 AS cliente_id,
    pmod(hash(id,'loj'),120)+1 AS loja_id,
    element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pais'),7)+1) AS pais,
    element_at(array('ELETRO','ALIMENTOS','CASA','MODA'), pmod(hash(id,'cat'),4)+1) AS categoria,
    element_at(array('LOJA','ONLINE'), pmod(hash(id,'can'),2)+1) AS canal,
    pmod(hash(id,'mes'),18) AS mes_idx
  FROM range(50000)
), s AS (
  SELECT *,
    -- anomalia: ~45% das vendas ELETRO/Chile de Q1-2026 "migram" para Q4-2025
    CASE WHEN categoria='ELETRO' AND pais='CL' AND mes_idx IN (12,13,14)
              AND pmod(hash(id,'shift'),100) < 45
         THEN element_at(array(9,10,11), pmod(hash(id,'q4'),3)+1)
         ELSE mes_idx END AS mes_final
  FROM b
)
SELECT venda_id, cliente_id, loja_id, pais, categoria, canal,
  date_add(add_months(DATE'2025-01-01', mes_final), pmod(hash(id,'day'),28)) AS data,
  round(CASE categoria WHEN 'ELETRO' THEN 800 WHEN 'ALIMENTOS' THEN 40
                       WHEN 'CASA' THEN 150 ELSE 90 END
        * (0.6 + pmod(hash(id,'amt'),800)/1000.0), 2) AS montante_usd
FROM s;

-- COMMAND ----------

-- 2.4 · Créditos do Cóndor Pagos (8.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_creditos AS
WITH b AS (
  SELECT id, id+1 AS credito_id,
    pmod(hash(id,'cli'),2000)+1 AS cliente_id,
    date_add(DATE'2025-01-01', pmod(hash(id,'orig'),545)) AS data_originacao,
    round(100 + pmod(hash(id,'m'),4900) + pmod(hash(id,'mc'),100)/100.0, 2) AS montante_usd,
    element_at(array(3,6,9,12,18,24), pmod(hash(id,'pz'),6)+1) AS prazo_meses,
    pmod(hash(id,'st'),100) AS st
  FROM range(8000)
)
SELECT credito_id, cliente_id, data_originacao, montante_usd, prazo_meses,
  CASE WHEN st < 15 THEN 'MOROSO' WHEN st < 40 THEN 'CANCELADO' ELSE 'ATIVO' END AS status,
  CASE WHEN st < 15 THEN 30 + pmod(hash(id,'atr'),91) ELSE pmod(hash(id,'atr2'),20) END AS dias_atraso
FROM b;

-- COMMAND ----------

-- 2.5 · Envios do Cóndor Cargo (30.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_envios AS
WITH b AS (
  SELECT id, id+1 AS envio_id,
    pmod(hash(id,'v'),50000)+1 AS venda_id,
    element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pd'),7)+1) AS pais_destino,
    date_add(DATE'2025-01-01', pmod(hash(id,'desp'),545)) AS data_despacho,
    pmod(hash(id,'e'),100) AS e,
    round(5 + pmod(hash(id,'cst'),45) + pmod(hash(id,'cc'),100)/100.0, 2) AS custo_envio_usd
  FROM range(30000)
), s AS (
  SELECT *,
    CASE WHEN (pais_destino='AR' AND e < 20) OR e < 8 THEN 'ATRASADO'
         WHEN e < 60 THEN 'ENTREGUE' ELSE 'EM_ROTA' END AS estado
  FROM b
)
SELECT envio_id, venda_id, pais_destino, data_despacho,
  CASE estado WHEN 'ENTREGUE' THEN date_add(data_despacho, 1+pmod(hash(id,'d1'),5))
              WHEN 'ATRASADO' THEN date_add(data_despacho, 6+pmod(hash(id,'d2'),10))
              ELSE NULL END AS data_entrega,
  estado, custo_envio_usd
FROM s;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3. Camada Gold (tabelas de negócio)

-- COMMAND ----------

-- 3.1 · Receita diária por país e unidade de negócio
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_receita_diaria AS
SELECT data, pais, 'VAREJO' AS unidade_negocio, round(sum(montante_usd),2) AS receita_usd
FROM workspace.grupo_condor.fact_vendas GROUP BY data, pais
UNION ALL
SELECT c.data_originacao AS data, cl.pais, 'PAGOS', round(sum(c.montante_usd*0.03),2)
FROM workspace.grupo_condor.fact_creditos c
JOIN workspace.grupo_condor.dim_clientes cl ON c.cliente_id=cl.cliente_id
WHERE c.status='ATIVO' GROUP BY c.data_originacao, cl.pais
UNION ALL
SELECT data_despacho AS data, pais_destino AS pais, 'CARGO', round(sum(custo_envio_usd),2)
FROM workspace.grupo_condor.fact_envios GROUP BY data_despacho, pais_destino;

-- COMMAND ----------

-- 3.2 · Vendas por categoria (dimensão de produto — essencial p/ a anomalia de ELETRO)
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_vendas_categoria AS
SELECT data, pais, categoria, round(sum(montante_usd),2) AS receita_usd, count(*) AS num_vendas
FROM workspace.grupo_condor.fact_vendas GROUP BY data, pais, categoria;

-- COMMAND ----------

-- 3.3 · Carteira de créditos (snapshot com faixa de mora)
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_carteira_creditos AS
SELECT credito_id, cliente_id, montante_usd AS saldo_estimado_usd, dias_atraso, status,
  CASE WHEN dias_atraso=0 THEN 'Em dia' WHEN dias_atraso<30 THEN '1-29'
       WHEN dias_atraso<60 THEN '30-59' WHEN dias_atraso<90 THEN '60-89'
       ELSE '90+' END AS faixa_mora
FROM workspace.grupo_condor.fact_creditos;

-- COMMAND ----------

-- 3.4 · OTIF de envios (entregas no prazo) por mês/país/estado
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_otif_envios AS
SELECT date_format(data_despacho,'yyyy-MM') AS mes, pais_destino, estado,
  count(*) AS num_envios,
  sum(CASE WHEN data_entrega IS NOT NULL AND datediff(data_entrega,data_despacho)<=5 THEN 1 ELSE 0 END) AS entregas_no_prazo
FROM workspace.grupo_condor.fact_envios GROUP BY 1,2,3;

-- COMMAND ----------

-- DBTITLE 1,Exercício 1
-- Exercício 1: Ranking de Receita do Varejo por Canal e Segmento de Cliente

-- • Objetivo de Negócio: O Diretor de Marketing quer saber quais canais (LOJA vs ONLINE) e segmentos de clientes (B2B vs B2C) trazem mais receita no varejo.
-- • O que você vai praticar: JOIN simples, SUM, GROUP BY e ORDER BY.
-- • Desafio: Faça um JOIN entre fact_vendas e dim_clientes. Agrupe os dados por canal e segmento, calculando o montante total vendido e a quantidade de vendas. Ordene do maior faturamento para o menor.

SELECT 
    ven.canal,
    cli.segmento,
    SUM(ven.montante_usd) AS total_receita,
    COUNT(ven.venda_id) AS quantidade_venda
FROM workspace.grupo_condor.fact_vendas ven
JOIN workspace.grupo_condor.dim_clientes cli 
    ON ven.cliente_id = cli.cliente_id
GROUP BY 
    ven.canal,
    cli.segmento
ORDER BY 
    total_receita DESC;

-- COMMAND ----------

-- Exercício 1: Ranking de Receita do Varejo por Canal e Segmento de Cliente

-- • Objetivo de Negócio: O Diretor de Marketing quer saber quais canais (LOJA vs ONLINE) e segmentos de clientes (B2B vs B2C) trazem mais receita no varejo.
-- • O que você vai praticar: JOIN simples, SUM, GROUP BY e ORDER BY.
-- • Desafio: Faça um JOIN entre fact_vendas e dim_clientes. Agrupe os dados por canal e segmento, calculando o montante total vendido e a quantidade de vendas. Ordene do maior faturamento para o menor.

select -- seleciono o canal e crio o apelido ven e seleciono o canal (da tabela de vendas) segmento(da tabela de clientes) com apelido criado cli.
ven.canal,
cli.segmento,
sum(ven.montante_usd) as montante_total_ven, -- soma o montante total de vendas
count(ven.venda_id) as quantidade_de_vendas -- conta a quantidade de vendas

from workspace.grupo_condor.fact_vendas as ven -- informo de onde vem o apelido ven craido, que é da tabela do grupo condor fact_vendas
join workspace.grupo_condor.dim_clientes as cli -- faço o join para informar o apelido cli criado, proveniente da tabela do gp condor dim_clientes
on ven.cliente_id = cli.cliente_id -- conexão entre as tabelas, pois em ambas temos o cliente_id com seus respectivos apelidos,

group by all  -- aqui coloco by all, pois acima já foram selecionados os canais e segmentos.
order by montante_total_ven DESC; -- ordeno pelo montante total de vendas de forma decrescente.




-- COMMAND ----------

-- DBTITLE 1,Exercício 2
-- Exercício 2: Perfil de Formato de Lojas por País

-- • Objetivo de Negócio: A equipe de expansão quer entender a distribuição de formatos de lojas (SUPER, EXPRESS, ONLINE) nos países onde o grupo atua.
-- • O que você vai praticar: COUNT, GROUP BY multi-coluna, filtros.
-- • Desafio: Utilizando a tabela dim_lojas, agrupe os dados por pais e formato. Mostre a quantidade de lojas para cada combinação, filtrando para excluir o formato 'ONLINE' da contagem, focando apenas nas lojas físicas.

SELECT 
    pais,
    formato, 
    COUNT(loja_id) AS quantidade_lojas
FROM workspace.grupo_condor.dim_lojas
WHERE formato != "ONLINE"
GROUP BY 
    pais,
    formato;

-- COMMAND ----------

-- Exercício 2: Perfil de Formato de Lojas por País

-- • Objetivo de Negócio: A equipe de expansão quer entender a distribuição de formatos de lojas (SUPER, EXPRESS, ONLINE) nos países onde o grupo atua.
-- • O que você vai praticar: COUNT, GROUP BY multi-coluna, filtros.
-- • Desafio: Utilizando a tabela dim_lojas, agrupe os dados por pais e formato. Mostre a quantidade de lojas para cada combinação, filtrando para excluir o formato 'ONLINE' da contagem, focando apenas nas lojas físicas.

SELECT -- seleciono o pais e o formato, por que não coloco os apelidos que criei no exercicio 1? pois aqui trabalho apenas com a tabela dim_lojas, enquanto no de cima eu tinha duas tabelas, então existiu a necessidade de criar apelidos para esses termos selecionados.
    pais,
    formato,
    count(loja_id) AS quantidade_lojas -- contagem de lojas_id para obter o resultado final em quantidade de lojas
    FROM workspace.grupo_condor.dim_lojas -- localizado na planilha dim_lojas
    WHERE formato != "ONLINE" -- filtro APENAS as lojas fisicas, != significa diferente,
    GROUP BY ALL -- mais uma vez coloco by all pq os parametros foram selecionados anteriormente, seria redundante se eu colocasse novamente aqui.


-- COMMAND ----------

-- DBTITLE 1,Exercício 3
-- Exercício 3: Cruzamento de Vendas e Logística (Ticket vs Custo de Envio)

-- • Objetivo de Negócio: A operação do Cóndor Cargo quer analisar se o custo do envio está muito alto em relação ao valor da mercadoria vendida para o país da Argentina ('AR').
-- • O que você vai praticar: JOIN múltiplo, AVG, WHERE.
-- • Desafio: Junte as tabelas fact_vendas e fact_envios através do venda_id. Filtre os dados onde o pais_destino seja 'AR'. Calcule a média do montante_usd da venda e a média do custo_envio_usd agrupados por categoria.

SELECT 
    v.categoria,
    round(avg(v.montante_usd), 2) AS media_venda_usd,
    round(avg(e.custo_envio_usd), 2) AS media_custo_envio_usd

FROM workspace.grupo_condor.fact_vendas v

JOIN workspace.grupo_condor.fact_envios e 

  ON v.venda_id = e.venda_id

WHERE e.pais_destino = 'AR'

GROUP BY v.categoria

ORDER BY media_venda_usd DESC;

-- COMMAND ----------

-- DBTITLE 1,Exercício 3
-- Exercício 3: Cruzamento de Vendas e Logística (Ticket vs Custo de Envio)

-- • Objetivo de Negócio: A operação do Cóndor Cargo quer analisar se o custo do envio está muito alto em relação ao valor da mercadoria vendida para o país da Argentina ('AR').
-- • O que você vai praticar: JOIN múltiplo, AVG, WHERE.
-- • Desafio: Junte as tabelas fact_vendas e fact_envios através do venda_id. Filtre os dados onde o pais_destino seja 'AR'. Calcule a média do montante_usd da venda e a média do custo_envio_usd agrupados por categoria.

SELECT
    ven.categoria,
    round(avg(ven.montante_usd), 2) AS media_montante_venda_usd,
    round(avg(env.custo_envio_usd), 2) AS media_custo_envio_usd
FROM workspace.grupo_condor.fact_vendas ven
JOIN workspace.grupo_condor.fact_envios env
    on ven.venda_id = env.venda_id
WHERE env.pais_destino = "AR"
GROUP BY ALL;

-- COMMAND ----------

-- DBTITLE 1,Exercício 4
-- Exercício 4: Análise de Risco de Crédito (Mora por País)

-- • Objetivo de Negócio: O Cóndor Pagos precisa consolidar a carteira de crédito para entender o impacto financeiro de clientes inadimplentes.
-- • O que você vai praticar: CASE WHEN interno no SUM, JOIN.
-- • Desafio: Utilizando a tabela gold_carteira_creditos e a dim_clientes, traga o pais do cliente, o valor total da carteira (saldo_estimado_usd) e o valor total que está na faixa de mora '90+'.

SELECT 
    cli.pais, 
    SUM(goldcartc.saldo_estimado_usd) AS carteira_total,

    SUM(
    CASE 
        WHEN faixa_mora = "90+"
        THEN saldo_estimado_usd
        ELSE 0
    END 
    ) AS carteira_mora_90_mais

FROM workspace.grupo_condor.gold_carteira_creditos goldcartc

JOIN workspace.grupo_condor.dim_clientes cli
    ON goldcartc.cliente_id = cli.cliente_id
GROUP BY 
    cli.pais
ORDER BY
    carteira_total DESC;



-- COMMAND ----------

-- DBTITLE 1,Exercício 5

-- Exercício 5: Participação Percentual da Categoria no País (Market Share Interno)
-- • Objetivo de Negócio: O time comercial precisa identificar qual o peso financeiro de cada categoria de produto dentro de cada país.
-- • O que você vai praticar: Window Function com SUM() OVER (PARTITION BY).
-- • Desafio: Utilizando a tabela gold_vendas_categoria, crie uma consulta que retorne: pais, categoria, a soma de receita_usd daquela categoria e uma coluna calculada com o % de representatividade daquela categoria sobre o total do respectivo país.

select -- seleciono os parametros
    pais,
    categoria,
    sum(receita_usd) as receita_categoria, -- somo a receita usd para me dar o resultado daquela categoria

    sum(sum(receita_usd)) over (partition by pais) as total_pais, -- somo o total de receita por pais, iniciando com as receitas diárias, depois da soma das receitas diárias eu faço a soma total daquele pais, assim conseguindo fazer a soma total do país sem perder as categorias em um único resultado.
    round(sum(receita_usd) / 
            sum(sum(receita_usd)) 
            over (partition by pais)*100, 2 
        ) as percentual_categoria -- para obtermos o percentual de cada categoria, precisamos dividir a soma daquela categoria pelo total do país, depois multiplicamos por 100 para obtermos o percentual, por fim arredondamos o resultado para 2 casas decimais.

from workspace.grupo_condor.gold_vendas_categoria -- dados utilizados da tabela gold_vendas_categoria

group by all -- coloco group all pois acima no select já indiquiei os parâmetros que serão utilizados. 

-- COMMAND ----------

-- DBTITLE 1,Exercício 6 - apenas últimos 3 meses
-- Exercício 6: Evolução Mensal da Receita e Média Móvel (Análise de Tendência)

-- • Objetivo de Negócio: O CFO quer avaliar a saúde financeira do grupo mês a mês, suavizando variações diárias abruptas.
-- • O que você vai praticar: date_format, Window Function de Linhas (ROWS BETWEEN).
-- • Desafio: Utilizando a tabela gold_receita_diaria, primeiro agrupe a receita por mês (ex: 2025-01). Em seguida, aplique uma Window Function para calcular a Média Móvel dos últimos 3 meses de receita acumulada do grupo.

with receita_mensal as ( -- crio inicialmente uma CTE (Common Table Expression, gostei de aprender sobre isso) para determinar como agrupar a receita financeira acumulada do grupo condor  por mês;

    select
        date_format(data, 'yyyy-MM') as mes,
        SUM(receita_usd) as receita_mensal -- primeiro agrupamos a receita_mensal por mês, informando qual é o formato de data que quero exibir no resultado final significando o mês. Após isso, eu denomino que a soma dos valores da coluna receita_usd será a receita_mensal.

    from workspace.grupo_condor.gold_receita_diaria -- a tabela a ser utilizada é a gold_receita_diaria

    group by date_format(data, 'yyyy-MM') -- agrupamos a receita_mensal por mês, informando qual é o formato de data que quero exibir no resultado final significando o mês.

)

select -- faço um select para exibir os resultados discutidos acima
    mes,
    receita_mensal,

    round(avg(receita_mensal) over ( 
        order by mes
        rows between 2 preceding and current row),2
        ) as  media_movel_3_meses -- aqui faço a media da receita_mensal usando a window function, onde a janela é definida por 3 meses, onde o 2 preceding indica que a janela começa 2 linhas antes da linha atual, e current row indica que a janela termina na linha atual
        
from receita_mensal -- aqui o from é de uma CTE criada acima, portanto não é necessário colocar o nome da tabela.
order by mes desc -- ordeno por mês em ordem decrescente
limit 3; -- adiciono um limite de apenas 3 meses, o que foi pedido pelo CTO.




-- COMMAND ----------

-- DBTITLE 1,Exercicio 6 - calculo com media movel por todos os meses
-- Exercício 6: Evolução Mensal da Receita e Média Móvel (Análise de Tendência)

-- • Objetivo de Negócio: O CFO quer avaliar a saúde financeira do grupo mês a mês, suavizando variações diárias abruptas.
-- • O que você vai praticar: date_format, Window Function de Linhas (ROWS BETWEEN).
-- • Desafio: Utilizando a tabela gold_receita_diaria, primeiro agrupe a receita por mês (ex: 2025-01). Em seguida, aplique uma Window Function para calcular a Média Móvel dos últimos 3 meses de receita acumulada do grupo.

with receita_mensal as ( -- crio inicialmente uma CTE (Common Table Expression, gostei de aprender sobre isso) para determinar como agrupar a receita financeira acumulada do grupo condor  por mês;

    select
        date_format(data, 'yyyy-MM') as mes,
        SUM(receita_usd) as receita_mensal -- primeiro agrupamos a receita_mensal por mês, informando qual é o formato de data que quero exibir no resultado final significando o mês. Após isso, eu denomino que a soma dos valores da coluna receita_usd será a receita_mensal.

    from workspace.grupo_condor.gold_receita_diaria -- a tabela a ser utilizada é a gold_receita_diaria

    group by date_format(data, 'yyyy-MM') -- agrupamos a receita_mensal por mês, informando qual é o formato de data que quero exibir no resultado final significando o mês.

)

select -- faço um select para exibir os resultados discutidos acima
    mes,
    receita_mensal,

    round(avg(receita_mensal) over ( 
        order by mes
        rows between 2 preceding and current row),2
        ) as  media_movel_3_meses -- aqui faço a media da receita_mensal usando a window function, onde a janela é definida por 3 meses, onde o 2 preceding indica que a janela começa 2 linhas antes da linha atual, e current row indica que a janela termina na linha atual
        
from receita_mensal -- aqui o from é de uma CTE criada acima, portanto não é necessário colocar o nome da tabela.
where mes >= '2025-03' -- por que seleciono o where? por que precisamos de 3 meses para calcular a média móvel, logo, o mês mais antigo que pode ser considerado é o 2025-03.
order by mes desc; -- ordenando por mês em ordem decrescente

