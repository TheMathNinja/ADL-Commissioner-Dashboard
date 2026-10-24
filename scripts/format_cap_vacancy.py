"""Format only Vac$ columns; preserve all workbook contents and other formats."""
import json, os, re
import gspread
from gspread.utils import rowcol_to_a1
client=gspread.service_account_from_dict(json.loads(os.environ['GOOGLE_SERVICE_ACCOUNT_JSON']))
book=client.open_by_key('1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw')
assert all(word in book.title.casefold() for word in ['2026','adl','contract','admin']), 'Unexpected workbook title'
sheet=book.worksheet('Cap Rollover')
before=sheet.get_all_values(value_render_option='FORMULA')
columns=sorted({c for row in before[:2] for c,label in enumerate(row) if re.fullmatch(r'(?:W\d+[_ ]*)?Vac\$',str(label).strip(),re.I)})
assert columns, 'No Vac$ header found; no edits made'
meta=book.fetch_sheet_metadata(params={'includeGridData':True,'ranges':"'Cap Rollover'!A3:ZZ3",'fields':'sheets(data(rowData(values(userEnteredFormat(numberFormat)))))'})
formats=meta['sheets'][0]['data'][0]['rowData'][0]['values']
currency={i:v.get('userEnteredFormat',{}).get('numberFormat',{}) for i,v in enumerate(formats)}
currency={i:f for i,f in currency.items() if f.get('type')=='CURRENCY'}
requests=[]
plans={}
for c in columns:
    pattern=currency[min(currency,key=lambda i:abs(i-c))]['pattern'] if currency else '"$"#,##0.00'
    fmt={'type':'CURRENCY','pattern':pattern}
    plans[c]=fmt
    requests.append({'repeatCell':{'range':{'sheetId':sheet.id,'startRowIndex':2,'startColumnIndex':c,'endColumnIndex':c+1},'cell':{'userEnteredFormat':{'numberFormat':fmt}},'fields':'userEnteredFormat.numberFormat'}})
book.batch_update({'requests':requests})
assert sheet.get_all_values(value_render_option='FORMULA')==before, 'Workbook contents changed during formatting; inspect concurrent edits'
meta=book.fetch_sheet_metadata(params={'includeGridData':True,'ranges':"'Cap Rollover'!A3:ZZ3",'fields':'sheets(data(rowData(values(userEnteredFormat(numberFormat)))))'})
saved=meta['sheets'][0]['data'][0]['rowData'][0]['values']
assert all(saved[c]['userEnteredFormat']['numberFormat']==fmt for c,fmt in plans.items()),'Formatting readback did not match'
print('Verified currency formatting for',len(columns),'Vac$ columns:',', '.join(rowcol_to_a1(1,c+1)[:-1] for c in columns))
print('All existing values and formulas are unchanged. Currency patterns match neighboring currency columns.')
