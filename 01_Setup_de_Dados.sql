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

-- DBTITLE 1,Exercício 2
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

-- DBTITLE 1,Exercício 3
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

-- DBTITLE 1,Exercício 4
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

select
    pais,
    categoria,
    sum(receita_usd) as receita_categoria,

    sum(sum(receita_usd)) over (partition by pais) as total_pais,
    round(sum(receita_usd) /
            sum(sum(receita_usd)) 
            over (partition by pais)*100, 2 
        ) as percentual_categoria

from workspace.grupo_condor.gold_vendas_categoria
--- sum(sum(receita_usd): 
--          - SUM interno: soma as receitas diárias para formar o total mensal;
--          - SUM externo: soma os totais mensais por país;
--  round(sum(receita_usd) / sum(sum(receita_usd)) over (partition by pais)*100, 2):
--          - SUM interno: soma as receitas por categoria para formar o total por país;
--          - SUM externo: soma os totais por país;
--          - over (partition by pais): agrupa os totais por país.

group by all 

-- COMMAND ----------

-- DBTITLE 1,Exercício 6 - apenas últimos 3 meses
-- Exercício 6: Evolução Mensal da Receita e Média Móvel (Análise de Tendência)

-- • Objetivo de Negócio: O CFO quer avaliar a saúde financeira do grupo mês a mês, suavizando variações diárias abruptas.
-- • O que você vai praticar: date_format, Window Function de Linhas (ROWS BETWEEN).
-- • Desafio: Utilizando a tabela gold_receita_diaria, primeiro agrupe a receita por mês (ex: 2025-01). Em seguida, aplique uma Window Function para calcular a Média Móvel dos últimos 3 meses de receita acumulada do grupo.

with receita_mensal as (

    select
        date_format(data, 'yyyy-MM') as mes,
        SUM(receita_usd) as receita_mensal

    from workspace.grupo_condor.gold_receita_diaria

    group by date_format(data, 'yyyy-MM')

)

select
    mes,
    receita_mensal,

    round(avg(receita_mensal) over (
        order by mes
        rows between 2 preceding and current row),2
        ) as  media_movel_3_meses
        
from receita_mensal
order by mes desc
limit 3;

-- with receita_mensal as: cria uma CTE (Common Table Expression) para agrupar a receita financeira acumulada do grupo condor  por mês;
-- group by date_format(data, 'yyyy-MM'): agrupa os resultados por mês no formato ANO-MÊS;
-- rows between 2 preceding and current row: define o intervalo de linhas para a Window Function, considerando os últimos 3 meses. ows between 2 preceding indica que a janela começa 2 linhas antes da linha atual, e current row indica que a janela termina na linha atual;
-- limit 3: limita o resultado a 3 linhas, mostrando os últimos 3 meses


-- COMMAND ----------

-- DBTITLE 1,Exercicio 6 - calculo com media movel por todos os meses
-- Exercício 6: Evolução Mensal da Receita e Média Móvel (Análise de Tendência)

-- • Objetivo de Negócio: O CFO quer avaliar a saúde financeira do grupo mês a mês, suavizando variações diárias abruptas.
-- • O que você vai praticar: date_format, Window Function de Linhas (ROWS BETWEEN).
-- • Desafio: Utilizando a tabela gold_receita_diaria, primeiro agrupe a receita por mês (ex: 2025-01). Em seguida, aplique uma Window Function para calcular a Média Móvel dos últimos 3 meses de receita acumulada do grupo.

with receita_mensal as (

    select
        date_format(data, 'yyyy-MM') as mes,
        SUM(receita_usd) as receita_mensal

    from workspace.grupo_condor.gold_receita_diaria

    group by date_format(data, 'yyyy-MM')

)

select
    mes,
    receita_mensal,

    round(avg(receita_mensal) over (
        order by mes
        rows between 2 preceding and current row),2
        ) as  media_movel_3_meses
        
from receita_mensal
where mes >= '2025-03'
order by mes desc;

-- Variação de resposta com a média móvel de todos os meses: 2025-03 até 2026-06, começando apenas na partir de março de 2025, pois a janela de 3 meses requer dados de pelo menos 3 meses anteriores.