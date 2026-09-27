-- ====================================================================================================
-- ПРОЕКТ: Оптимизация складских запасов и ABC-анализ ассортимента
-- КОМПАНИЯ: Global Foods & Beverages
-- АВТОР: Виктория
-- ====================================================================================================

-- ====================================================================================================
-- ЗАДАЧА 1: ABC-анализ ассортимента
-- Цель:     Сегментировать товары по принципу Парето (80/20) для выявления 
--           хитовых позиций (группа А), середнячков (группа B) и аутсайдеров (группа C)
-- ====================================================================================================
SELECT *
FROM products p

WITH product_revenue AS (
    /* 
       Шаг 1. Агрегация выручки по товарам.
       Соединяем товары, детали заказов и категории. 
       Считаем SUM(quantity * unit_price) для каждого продукта.
    */
    SELECT 
        p.product_id,
        p.product_name,
        c.category_name,
        SUM(od.quantity * od.unit_price) AS revenue
    FROM products p
    JOIN order_details od ON p.product_id = od.product_id
    JOIN categories c ON p.category_id = c.category_id
    GROUP BY p.product_id, p.product_name, c.category_name
),
abc_calc AS (
    /* 
       Шаг 2. Расчет кумулятивной доли (накопительного итога).
       Используем оконные функции, чтобы не схлопывать строки через GROUP BY.
       SUM() OVER(ORDER BY...) дает бегущую сумму, SUM() OVER() дает общий итог.
    */
    SELECT 
        product_id,
        product_name,
        category_name,
        revenue,
        SUM(revenue) OVER(ORDER BY revenue DESC) / SUM(revenue) OVER() AS cum_share 
    FROM product_revenue
)
/* 
   Шаг 3. Финальное форматирование и присвоение групп A, B, C.
   Приводим к numeric, чтобы избежать целочисленного деления.
*/
SELECT 
    product_id,
    product_name,
    category_name,
    ROUND(revenue::numeric, 2) AS revenue,
    ROUND(cum_share::numeric * 100, 2) AS cum_share_percent,
    CASE 
        WHEN cum_share <= 0.80 THEN 'A'
        WHEN cum_share <= 0.95 THEN 'B'
        ELSE 'C'
    END AS abc_group
FROM abc_calc
ORDER BY revenue DESC;

-- ====================================================================================================
-- ЗАДАЧА 2: Поиск дефицита хитов и неликвидного ассортимента
-- Цель:     Выявить товары категории «А» с нулевым складским остатком (упущенная выгода) 
--           и товары без продаж за весь период (мертвый груз)
-- ====================================================================================================

WITH abc_groups AS (
    /* 
       Шаг 1. Расчет выручки и кумулятивной доли для ВСЕХ товаров.
       
       КЛЮЧЕВОЕ ОТЛИЧИЕ от Задачи 1: используем LEFT JOIN вместо INNER JOIN.
       Это нужно, чтобы захватить даже те товары, которые НИ РАЗУ не продавались 
       (у них не будет записей в order_details, и revenue будет NULL).
       
       Если бы использовали INNER JOIN, непроданные товары исчезли бы из выборки.
    */
    SELECT 
        p.product_id,
        p.product_name,
        p.units_in_stock,
        SUM(od.quantity * od.unit_price) AS revenue,
        /* 
           Вложенная агрегация внутри оконной функции:
           SUM(SUM(...)) OVER(...) - сначала считаем SUM по GROUP BY, 
           потом применяем оконную SUM к результату.
        */
        SUM(SUM(od.quantity * od.unit_price)) OVER(
            ORDER BY SUM(od.quantity * od.unit_price) DESC
        ) / SUM(SUM(od.quantity * od.unit_price)) OVER() AS cum_share
    FROM products p
    LEFT JOIN order_details od ON p.product_id = od.product_id
    GROUP BY p.product_id, p.product_name, p.units_in_stock
)
/*
   Шаг 2. Классификация товаров по статусу складских остатков.
   
   Используем CASE WHEN для присвоения статуса:
   - Если revenue IS NULL → товар ни разу не продавался (неликвид)
   - Если товар в группе А (cum_share <= 0.80) И остаток = 0 → дефицит хита
   - Иначе → статус ОК
*/
SELECT 
    product_id,
    product_name,
    units_in_stock,
    ROUND(revenue::numeric, 2) AS revenue,
    ROUND(cum_share::numeric * 100, 2) AS cum_share_percent,
    CASE 
        WHEN revenue IS NULL THEN 'Неликвид (нет продаж)'
        WHEN cum_share <= 0.80 AND units_in_stock = 0 THEN 'Дефицит хита (Группа А)'
        ELSE 'ОК'
    END AS stock_status
FROM abc_groups
/*
   Шаг 3. Фильтрация только проблемных товаров.
   
   Показываем только:
   - Товары группы А с нулевым остатком (дефицит хитов)
   - Товары без продаж (неликвид, revenue IS NULL)
   
   NULLS LAST - чтобы непроданные товары (с revenue = NULL) шли в конце списка.
*/
WHERE (cum_share <= 0.80 AND units_in_stock = 0) 
   OR revenue IS NULL
ORDER BY revenue DESC NULLS LAST;

-- ====================================================================================================
-- ЗАДАЧА 3.1: Рейтинг поставщиков хитовых товаров (группа А)
-- Цель:       Ранжировать поставщиков по выручке от товаров группы А
-- ====================================================================================================

WITH product_abc AS (
    /* Шаг 1. Определяем, какие товары входят в группу А */
    SELECT 
        p.product_id,
        SUM(od.quantity * od.unit_price) AS revenue,
        SUM(SUM(od.quantity * od.unit_price)) OVER(
            ORDER BY SUM(od.quantity * od.unit_price) DESC
        ) / SUM(SUM(od.quantity * od.unit_price)) OVER() AS cum_share
    FROM products p
    JOIN order_details od ON p.product_id = od.product_id
    GROUP BY p.product_id
),
supplier_revenue AS (
    /* Шаг 2. Считаем выручку по поставщикам ТОЛЬКО для товаров группы А */
    SELECT 
        s.supplier_id,
        s.company_name AS supplier_name,
        SUM(od.quantity * od.unit_price) AS revenue_a
    FROM suppliers s
    JOIN products p ON s.supplier_id = p.supplier_id
    JOIN order_details od ON p.product_id = od.product_id
    WHERE p.product_id IN (
        SELECT product_id FROM product_abc WHERE cum_share <= 0.80
    )
    GROUP BY s.supplier_id, s.company_name
)
/* 
   Шаг 3. Ранжируем поставщиков.
   
   DENSE_RANK() — плотное ранжирование БЕЗ разрывов.
   Если два поставщика делят 2-е место, следующий будет 3-м (не 4-м).
*/
SELECT 
    supplier_id,
    supplier_name,
    ROUND(revenue_a::numeric, 2) AS revenue_a,
    DENSE_RANK() OVER(ORDER BY revenue_a DESC) AS supplier_rank
FROM supplier_revenue
ORDER BY supplier_rank;

-- Проверка: какие товары поставляет каждый из топ-3 поставщиков
SELECT 
    s.supplier_id,
    s.company_name AS supplier_name,
    p.product_name,
    SUM(od.quantity * od.unit_price) AS revenue
FROM suppliers s
JOIN products p ON s.supplier_id = p.supplier_id
JOIN order_details od ON p.product_id = od.product_id
WHERE s.supplier_id IN (18, 12, 28)  -- ID топ-3 поставщиков
GROUP BY s.supplier_id, s.company_name, p.product_name
ORDER BY s.supplier_id, revenue DESC;

-- ====================================================================================================
-- ЗАДАЧА 3.2: Анализ тренда продаж топ-товара (Côte de Blaye, ID 38)
-- Цель:       Рассчитать скользящее среднее за 3 месяца для сглаживания сезонности
-- ====================================================================================================

SELECT 
    to_char(o.order_date, 'YYYY-MM') AS month,
    SUM(od.quantity * od.unit_price) AS monthly_revenue,
    /*
       Скользящее среднее за 3 месяца:
       - ORDER BY month — сортируем по времени
       - ROWS BETWEEN 2 PRECEDING AND CURRENT ROW — берём текущий месяц + 2 предыдущих
       
       Пример: для марта считаем среднее по январь, февраль, март
    */
    AVG(SUM(od.quantity * od.unit_price)) OVER(
        ORDER BY to_char(o.order_date, 'YYYY-MM') 
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3m
FROM order_details od
JOIN orders o ON od.order_id = o.order_id
WHERE od.product_id = 38  /* Côte de Blaye — топ-товар из Задачи 1 */
GROUP BY to_char(o.order_date, 'YYYY-MM')
ORDER BY month;

-- ====================================================================================================
-- ЗАДАЧА 4: Создание витрины данных (Data Mart) для BI-систем
-- Цель:     Сохранить результаты ABC-анализа в отдельную таблицу для BI-инструментов
-- ====================================================================================================

-- Шаг 1. Удаляем старую временную таблицу, если она осталась в памяти сессии
   DROP TABLE IF EXISTS abc_inventory_mart;

/* Шаг 2. Создаём временную таблицу abc_inventory_mart на основе аналитического запроса */
CREATE TEMP TABLE abc_inventory_mart AS

WITH product_revenue AS (
    /*
       Шаг 3. Агрегация выручки по каждому товару с присоединением всех атрибутов.
       
       JOIN order_details — для получения данных о продажах (количество и цена)
       JOIN categories    — для названия категории (нужно для BI-отчётов)
       JOIN suppliers     — для названия поставщика (нужно для анализа эффективности)
    */
    SELECT 
        p.product_id,
        p.product_name,
        c.category_name,
        s.company_name AS supplier_name,
        p.units_in_stock,
        SUM(od.quantity * od.unit_price) AS revenue
    FROM products p
    JOIN order_details od ON p.product_id = od.product_id
    JOIN categories c ON p.category_id = c.category_id
    JOIN suppliers s ON p.supplier_id = s.supplier_id
    GROUP BY p.product_id, p.product_name, c.category_name, 
             s.company_name, p.units_in_stock
),

abc_calc AS (
    /*
       Шаг 4. Расчёт кумулятивной доли и присвоение групп A, B, C.
       
       SUM(revenue) OVER(ORDER BY revenue DESC) — накопительная сумма от самого дорогого товара
       SUM(revenue) OVER() — общая сумма выручки по всем товарам
       Деление даёт кумулятивный процент (от 0 до 1)
       
       CASE WHEN присваивает группу:
       - A: топ-товары, дающие первые 80% выручки
       - B: следующие 15% (до 95%)
       - C: оставшиеся 5%
    */
    SELECT 
        product_id,
        product_name,
        category_name,
        supplier_name,
        units_in_stock,
        revenue,
        SUM(revenue) OVER(ORDER BY revenue DESC) / SUM(revenue) OVER() AS cum_share,
        CASE 
            WHEN SUM(revenue) OVER(ORDER BY revenue DESC) / SUM(revenue) OVER() <= 0.80 THEN 'A'
            WHEN SUM(revenue) OVER(ORDER BY revenue DESC) / SUM(revenue) OVER() <= 0.95 THEN 'B'
            ELSE 'C'
        END AS abc_group
    FROM product_revenue
)

/*
   Шаг 5. Финальный SELECT — формируем структуру витрины для BI-систем.
   
   Добавляем столбец stock_status с бизнес-статусом:
   - 'Дефицит хита' — товар группы А с нулевым остатком (критично!)
   - 'Кандидат на вывод' — товар группы C (аутсайдер, занимает место на складе)
   - 'ОК' — всё в порядке
   
   ::numeric нужен для избежания целочисленного деления
   ROUND(..., 2) — округление до 2 знаков для читаемости
*/
SELECT 
    product_id,
    product_name,
    category_name,
    supplier_name,
    units_in_stock,
    ROUND(revenue::numeric, 2) AS revenue,
    ROUND(cum_share::numeric * 100, 2) AS cum_share_percent,
    abc_group,
    CASE 
        WHEN abc_group = 'A' AND units_in_stock = 0 THEN 'Дефицит хита'
        WHEN abc_group = 'C' THEN 'Кандидат на вывод'
        ELSE 'ОК'
    END AS stock_status
FROM abc_calc
ORDER BY revenue DESC;

/*
   Шаг 6. Проверочный запрос — убеждаемся, что таблица создалась и заполнена.
   Должно быть 77 строк (по числу товаров в базе).
*/
SELECT * FROM abc_inventory_mart;