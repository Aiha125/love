import json
# json : 파이썬 객체 ↔ JSON 문자열 변환용 표준 라이브러리

import boto3
# boto3 : AWS용 파이썬 SDK. Lambda 실행 환경에 기본 포함되어 있어 따로 설치할 필요가 없다.


# ─────────────────────────────────────────────
# 전역 영역 : 함수 밖에 쓴 코드
# ─────────────────────────────────────────────
# 여기 있는 코드는 "콜드 스타트" 때 딱 한 번만 실행되고,
# 이후 같은 컨테이너가 재사용되는 동안에는 다시 실행되지 않는다.
# 그래서 연결 객체 생성처럼 무거운 작업은 전역에 두는 것이 성능상 유리하다.

dynamodb = boto3.resource('dynamodb', region_name='ap-northeast-2')
# boto3.resource : 객체 지향 방식의 상위 레벨 인터페이스
#                  (boto3.client 는 API를 그대로 호출하는 하위 레벨 방식)
# region_name    : 접속할 리전

table = dynamodb.Table('wskorea26-data-table')
# 다룰 테이블을 지정
# 참고: 테이블 이름이 코드에 박혀 있다.
#       환경변수 TABLE_NAME이 채점 항목이므로
#       os.environ['TABLE_NAME'] 으로 읽게 바꾸는 편이 안전하다.


def lambda_handler(event, context):
    # lambda_handler : Lambda가 호출할 진입점 함수.
    #                  함수 설정의 "핸들러" 값이 파일명.함수명 형식으로
    #                  여기를 가리켜야 한다 (예: lambda_function.lambda_handler).
    # event   : 호출한 쪽이 넘겨준 입력 데이터. ALB가 호출하면 HTTP 요청 정보가 담긴다.
    # context : 실행 환경 정보(남은 시간, 요청 ID 등). 여기선 쓰지 않는다.

    query_params = event.get('queryStringParameters') or {}
    # event.get('키') : 딕셔너리에서 값을 꺼내되, 키가 없으면 None을 반환(에러 안 남)
    #                   event['키'] 로 쓰면 키가 없을 때 KeyError로 죽는다.
    # queryStringParameters : URL의 ?뒤에 붙은 값들.
    #                         예) ?concert_name=ABC → {'concert_name': 'ABC'}
    # or {}   : 앞의 값이 None이거나 비어 있으면 빈 딕셔너리를 쓴다.
    #           쿼리가 아예 없으면 이 키의 값이 None이라 그대로 두면 다음 줄에서 죽는다.

    concert_name = query_params.get('concert_name')
    # 조회할 콘서트 이름을 꺼냄. 없으면 None.

    if not concert_name:
        return create_alb_response(400, {"message": "Bad Request: concert_name is required"})
    # not X : X가 None, 빈 문자열, 0 등 "거짓 같은 값"이면 참
    # 400   : Bad Request. 클라이언트가 필수 파라미터를 빠뜨렸다는 표준 상태 코드.

    target_name = concert_name.strip()
    # strip() : 문자열 앞뒤의 공백·줄바꿈 제거.
    #           " ABC " 로 들어와도 "ABC"와 매칭되게 하려는 방어 코드.

    try:
        # try / except : 예외 처리 구문.
        #                try 안에서 에러가 나면 except 블록으로 넘어간다.
        #                DB 호출은 네트워크·권한 문제로 실패할 수 있으므로 감싼다.

        response = table.scan()
        # scan() : 테이블의 "모든" 항목을 처음부터 끝까지 읽는다.
        #          Query와 달리 인덱스를 타지 않아 데이터가 많으면 느리고 비싸다.
        #          여기서는 concert_name이 기본 키가 아니라 Query를 쓸 수 없어 scan을 쓴 것.
        #          (기본 키는 client_id)

        all_items = response.get('Items', [])
        # get('Items', []) : 두 번째 인자는 "키가 없을 때 돌려줄 기본값".
        #                    결과가 없어도 빈 리스트가 되어 아래 반복문이 안전하게 돈다.

        filtered_items = []
        # 조건에 맞는 항목을 담을 빈 리스트

        for item in all_items:
            # for ... in ... : 리스트의 각 원소를 하나씩 꺼내 반복

            db_concert_name = item.get('concert_name')
            # 각 항목에서 concert_name 값을 꺼냄.
            # DynamoDB는 항목마다 속성이 달라도 되므로 없을 수 있다 → get 사용.

            if db_concert_name is not None:
                # is not None : "값이 존재하는가" 판정.
                #               != None 보다 is not None 이 파이썬 관례.

                if str(db_concert_name).strip() == target_name:
                    # str(...) : 숫자 등 다른 타입으로 저장돼 있어도 문자열로 통일해 비교
                    # .strip() : DB에 저장된 값의 앞뒤 공백도 제거
                    # ==       : 값이 같은지 비교 (= 는 대입이라 조건문에 못 씀)

                    filtered_items = filtered_items + [item]
                    # 리스트 + 리스트 = 이어붙인 새 리스트.
                    # filtered_items.append(item) 이 더 일반적이고 빠르지만 결과는 같다.

        if filtered_items:
            # 리스트가 비어 있지 않으면 참 (빈 리스트는 거짓)

            filtered_items.sort(key=lambda x: x.get('created_at', ''), reverse=True)
            # sort()       : 리스트를 제자리에서 정렬 (새 리스트를 만들지 않음)
            # key=         : 무엇을 기준으로 정렬할지 정하는 함수
            # lambda x: .. : 이름 없는 한 줄짜리 함수.
            #                x는 리스트의 각 항목, created_at 값을 정렬 기준으로 돌려준다.
            #                created_at이 없으면 빈 문자열을 써서 에러를 피한다.
            # reverse=True : 내림차순. 최신 예약이 앞으로 온다.

        return create_alb_response(200, filtered_items)
        # 200 : OK. 조건에 맞는 항목이 하나도 없어도 빈 배열과 함께 200을 돌려준다.

    except Exception as e:
        # Exception : 거의 모든 에러의 부모 클래스. 어떤 에러든 여기서 잡힌다.
        # as e      : 잡은 에러 객체를 e라는 이름으로 사용

        print(f"Error scanning DynamoDB: {str(e)}")
        # print   : Lambda에서 print한 내용은 CloudWatch Logs에 자동 기록된다.
        #           디버깅의 기본 수단.
        # f"..."  : f-string. 문자열 안 {중괄호}에 변수 값을 끼워 넣는 문법.

        return create_alb_response(500, {"message": "Internal Server Error"})
        # 500 : 서버 내부 오류. 에러 상세 내용을 사용자에게 노출하지 않고
        #       로그에만 남기는 것이 보안상 올바른 처리다.


def create_alb_response(status_code, body_data):
    # 응답 형식을 한 곳에서 만들어 쓰는 헬퍼 함수.
    # ALB가 Lambda를 직접 호출할 때는 반드시 정해진 형태로 돌려줘야 하며,
    # 형식이 틀리면 ALB가 502 Bad Gateway를 낸다.

    return {
        "isBase64Encoded": False,
        # 본문이 base64로 인코딩됐는지 여부. 이미지 같은 바이너리면 True.
        # 여기선 일반 텍스트(JSON)라 False.

        "statusCode": status_code,
        # HTTP 상태 코드 (숫자)

        "statusDescription": f"{status_code} OK" if status_code == 200 else f"{status_code} Error",
        # 상태 줄에 들어갈 설명 문구.
        # A if 조건 else B : 파이썬의 삼항 연산자.
        #   조건이 참이면 A, 거짓이면 B를 값으로 갖는다.
        #   200이면 "200 OK", 아니면 "400 Error" 같은 문자열이 된다.

        "headers": {
            "Content-Type": "application/json; charset=utf-8"
            # 본문이 JSON이고 UTF-8 인코딩임을 브라우저에 알림.
            # charset=utf-8 이 없으면 한글이 깨져 보일 수 있다.
        },

        "body": json.dumps(body_data, ensure_ascii=False)
        # body는 반드시 "문자열"이어야 한다. 딕셔너리를 그대로 넣으면 오류.
        # json.dumps        : 파이썬 객체 → JSON 문자열
        # ensure_ascii=False: 기본값 True면 한글이 \uXXXX 형태로 이스케이프된다.
        #                     False로 두어야 한글이 그대로 보인다.
    }
